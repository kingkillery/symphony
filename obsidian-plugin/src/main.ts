import { mkdir, writeFile } from "fs/promises";
import { join } from "path";
import {
	App,
	MarkdownView,
	Notice,
	Plugin,
	PluginSettingTab,
	Setting,
	TAbstractFile,
	TFile,
	WorkspaceLeaf,
	normalizePath,
} from "obsidian";
import {
	type ExecutionJob,
	type ExecutionJobSummary,
	type ExecutionStartResult,
	NodeExecutionProcessRunner,
	summarizeExecutionJob,
} from "./execution-layer";
import { buildIssueIndex, type IndexedIssue, type IssueIndexSnapshot } from "./issue-index";
import { DEFAULT_SETTINGS, type SymphonySettings } from "./settings";
import {
	EMPTY_WORKFLOW_CONFIG,
	loadWorkflowConfig,
	mergeSettingsWithWorkflow,
	type WorkflowConfigSnapshot,
} from "./workflow-config";
import { syncTaskPluginMetadata, TASK_PLUGIN_TAG, issueStateToTaskPluginStatus, normalizeSymphonyIssueState } from "./task-plugin-compat";
import {
	SYMPHONY_DASHBOARD_VIEW_TYPE,
	SymphonyDashboardView,
} from "./ui/symphony-dashboard-view";

interface ActiveExecution {
	issuePath: string;
	issueTitle: string;
	attempt: number;
	startedAt: number;
	startResult: ExecutionStartResult;
}

interface RetryEntry {
	issuePath: string;
	issueTitle: string;
	attempts: number;
	dueAt: number;
	reason: string;
}

interface PersistedActiveIssue {
	issuePath: string;
	issueTitle: string;
	attempt: number;
	startedAt: number;
}

interface PersistedRuntimeState {
	recentExecutions: ExecutionJob[];
	retryQueue: RetryEntry[];
	activeIssues: PersistedActiveIssue[];
}

interface PersistedPluginData {
	settings: SymphonySettings;
	runtime: PersistedRuntimeState;
}

const COMPLETED_RUNTIME_STATES = new Set(["completed", "failed", "cancelled"]);
const TERMINAL_NOTE_STATES = new Set(["done", "closed", "cancelled", "canceled", "archive", "archived"]);
const HUMAN_REVIEW_STATE = "Human Review";
const RETRY_BASE_DELAY_MS = 5_000;
const RETRY_MAX_DELAY_MS = 60_000;

export default class SymphonyPlugin extends Plugin {
	settings: SymphonySettings = DEFAULT_SETTINGS;
	private workflowConfig: WorkflowConfigSnapshot = EMPTY_WORKFLOW_CONFIG;
	private issueIndex: IssueIndexSnapshot | null = null;
	private refreshTimeout: number | null = null;
	private retryTimeout: number | null = null;
	private isUnloading = false;
	private readonly processRunner = new NodeExecutionProcessRunner();
	private readonly activeExecutions = new Map<string, ActiveExecution>();
	private readonly retryQueue = new Map<string, RetryEntry>();
	private recentExecutions: ExecutionJob[] = [];
	private persistedActiveIssues: PersistedActiveIssue[] = [];
	private readonly finalizedJobIds = new Set<string>();
	private readonly noRetryJobIds = new Set<string>();

	async onload(): Promise<void> {
		await this.loadPluginData();
		this.registerView(
			SYMPHONY_DASHBOARD_VIEW_TYPE,
			(leaf) =>
				new SymphonyDashboardView(
					leaf,
					() => this.getEffectiveSettings(),
					() => this.issueIndex,
					() => this.getExecutionSummaries(),
				),
		);

		this.addSettingTab(new SymphonySettingTab(this.app, this));
		this.registerCommands();
		this.registerVaultEvents();

		this.app.workspace.onLayoutReady(() => {
			void this.initializeRuntime();

			if (this.getEffectiveSettings().dashboardOpenOnStart) {
				void this.activateDashboardView();
			}

			if (this.getEffectiveSettings().autoStart) {
				new Notice("Symphony runtime loaded. Project-related Obsidian tasks will dispatch when eligible.", 7000);
			}
		});
	}

	async onunload(): Promise<void> {
		this.isUnloading = true;
		this.clearTimers();
		await this.persistPluginData();
		await Promise.all(
			Array.from(this.activeExecutions.values(), (execution) => execution.startResult.cancel("Plugin unloaded")),
		);
		await this.app.workspace.detachLeavesOfType(SYMPHONY_DASHBOARD_VIEW_TYPE);
	}

	getIssueIndex(): IssueIndexSnapshot | null {
		return this.issueIndex;
	}

	getExecutionSummaries(): ExecutionJobSummary[] {
		const running = Array.from(this.activeExecutions.values(), (execution) =>
			summarizeExecutionJob(execution.startResult.runningJob),
		);
		const completed = this.recentExecutions.map((job) => summarizeExecutionJob(job));
		return [...running, ...completed].slice(0, 20);
	}

	getEffectiveSettings(): SymphonySettings {
		return mergeSettingsWithWorkflow(this.settings, this.workflowConfig);
	}

	async saveSettings(): Promise<void> {
		this.normalizeSettings();
		await this.persistPluginData();
		await this.refreshIssueIndex();
		this.rerenderDashboardViews();
	}

	private async initializeRuntime(): Promise<void> {
		await this.refreshIssueIndex();
		await this.recoverInterruptedExecutions();
		await this.refreshIssueIndex();
	}

	private async loadPluginData(): Promise<void> {
		const data = await this.loadData();
		if (isPersistedPluginData(data)) {
			this.settings = Object.assign({}, DEFAULT_SETTINGS, data.settings);
			this.recentExecutions = limitExecutionJobs(data.runtime.recentExecutions);
			this.persistedActiveIssues = Array.isArray(data.runtime.activeIssues) ? data.runtime.activeIssues : [];
			for (const retry of data.runtime.retryQueue ?? []) {
				if (isRetryEntry(retry)) {
					this.retryQueue.set(retry.issuePath, retry);
				}
			}
		} else {
			this.settings = Object.assign({}, DEFAULT_SETTINGS, data ?? {});
			this.recentExecutions = [];
			this.persistedActiveIssues = [];
		}

		this.normalizeSettings();
	}

	private async persistPluginData(): Promise<void> {
		await this.saveData({
			settings: this.settings,
			runtime: {
				recentExecutions: this.recentExecutions.slice(0, 20),
				retryQueue: Array.from(this.retryQueue.values()),
				activeIssues: Array.from(this.activeExecutions.values(), (execution) => ({
					issuePath: execution.issuePath,
					issueTitle: execution.issueTitle,
					attempt: execution.attempt,
					startedAt: execution.startedAt,
				})),
			},
		} satisfies PersistedPluginData);
	}

	private normalizeSettings(): void {
		this.settings.issueFolderPath = normalizePath(this.settings.issueFolderPath);
		this.settings.workflowFilePath = normalizePath(this.settings.workflowFilePath);
		this.settings.symphonyInstanceId = this.settings.symphonyInstanceId.trim();
		this.settings.maxConcurrentRuns = Math.max(1, Number(this.settings.maxConcurrentRuns) || 1);
		this.settings.runnerTimeoutMs =
			this.settings.runnerTimeoutMs === null || this.settings.runnerTimeoutMs === undefined
				? null
				: Math.max(1_000, Number(this.settings.runnerTimeoutMs) || 0);
	}

	private rerenderDashboardViews(): void {
		for (const leaf of this.app.workspace.getLeavesOfType(SYMPHONY_DASHBOARD_VIEW_TYPE)) {
			if (leaf.view instanceof SymphonyDashboardView) {
				leaf.view.render();
			}
		}
	}

	private clearTimers(): void {
		if (this.refreshTimeout !== null) {
			window.clearTimeout(this.refreshTimeout);
			this.refreshTimeout = null;
		}
		if (this.retryTimeout !== null) {
			window.clearTimeout(this.retryTimeout);
			this.retryTimeout = null;
		}
	}

	private registerCommands(): void {
		this.addCommand({
			id: "open-dashboard",
			name: "Open dashboard",
			callback: async () => {
				await this.activateDashboardView();
			},
		});

		this.addCommand({
			id: "refresh-now",
			name: "Refresh now",
			callback: async () => {
				const snapshot = await this.refreshIssueIndex();
				new Notice(
					`Symphony refreshed ${snapshot.projectRelatedCount} project task(s); ${snapshot.eligibleCount} eligible for work.`,
					5000,
				);
			},
		});

		this.addCommand({
			id: "create-symphony-task-note",
			name: "Create Symphony task",
			callback: async () => {
				await this.createSymphonyTaskNote();
			},
		});

		this.addCommand({
			id: "assign-current-note-to-symphony",
			name: "Assign current note to Symphony",
			editorCheckCallback: (checking) => {
				const view = this.app.workspace.getActiveViewOfType(MarkdownView);
				if (!view?.file) {
					return false;
				}

				if (!checking) {
					void this.assignCurrentNoteToSymphony(view.file);
				}

				return true;
			},
		});

		this.addCommand({
			id: "run-current-issue",
			name: "Run current issue",
			editorCheckCallback: (checking) => {
				const view = this.app.workspace.getActiveViewOfType(MarkdownView);
				if (!view?.file) {
					return false;
				}

				if (!checking) {
					void this.dispatchCurrentIssue(view.file);
				}

				return true;
			},
		});

		this.addCommand({
			id: "stop-current-issue",
			name: "Stop current issue",
			editorCheckCallback: (checking) => {
				const view = this.app.workspace.getActiveViewOfType(MarkdownView);
				if (!view?.file) {
					return false;
				}

				if (!checking) {
					void this.stopCurrentIssue(view.file);
				}

				return true;
			},
		});
	}

	private registerVaultEvents(): void {
		const refresh = (file: TAbstractFile | null | undefined) => {
			if (!file || this.shouldRefreshForFile(file.path)) {
				this.scheduleRefresh();
			}
		};

		this.registerEvent(this.app.vault.on("create", (file) => refresh(file)));
		this.registerEvent(this.app.vault.on("modify", (file) => refresh(file)));
		this.registerEvent(this.app.vault.on("delete", (file) => refresh(file)));
		this.registerEvent(this.app.vault.on("rename", (file, oldPath) => {
			if (this.shouldRefreshForFile(oldPath)) {
				this.scheduleRefresh();
				return;
			}
			refresh(file);
		}));
		this.registerEvent(this.app.metadataCache.on("changed", (file) => refresh(file)));
	}

	private shouldRefreshForFile(path: string): boolean {
		const normalizedPath = normalizePath(path);
		const effective = this.getEffectiveSettings();
		return (
			normalizedPath === this.settings.workflowFilePath ||
			(normalizedPath.endsWith(".md") &&
				(normalizedPath === effective.issueFolderPath || normalizedPath.startsWith(`${effective.issueFolderPath}/`)))
		);
	}

	private scheduleRefresh(): void {
		if (this.refreshTimeout !== null) {
			window.clearTimeout(this.refreshTimeout);
		}

		this.refreshTimeout = window.setTimeout(() => {
			this.refreshTimeout = null;
			void this.refreshIssueIndex();
		}, 200);
	}

	private scheduleRetryReconcile(): void {
		if (this.retryTimeout !== null) {
			window.clearTimeout(this.retryTimeout);
			this.retryTimeout = null;
		}

		const effective = this.getEffectiveSettings();
		if (!effective.autoDispatchProjectTasks || this.retryQueue.size === 0) {
			return;
		}

		const nextDueAt = Math.min(...Array.from(this.retryQueue.values(), (entry) => entry.dueAt));
		const delay = Math.max(0, nextDueAt - Date.now());
		this.retryTimeout = window.setTimeout(() => {
			this.retryTimeout = null;
			void this.refreshIssueIndex();
		}, delay);
	}

	private async refreshWorkflowConfig(): Promise<void> {
		this.workflowConfig = loadWorkflowConfig(this.app.vault, this.app.metadataCache, this.settings.workflowFilePath);
	}

	private async refreshIssueIndex(): Promise<IssueIndexSnapshot> {
		await this.refreshWorkflowConfig();
		const effective = this.getEffectiveSettings();
		this.issueIndex = buildIssueIndex(
			this.app.vault,
			effective,
			(file) => this.app.metadataCache.getFileCache(file),
		);
		this.rerenderDashboardViews();
		this.scheduleRetryReconcile();
		await this.reconcileExecution();
		return this.issueIndex;
	}

	private async recoverInterruptedExecutions(): Promise<void> {
		if (this.persistedActiveIssues.length === 0) {
			return;
		}

		const effective = this.getEffectiveSettings();
		const interrupted = [...this.persistedActiveIssues];
		this.persistedActiveIssues = [];

		for (const snapshot of interrupted) {
			const file = this.app.vault.getAbstractFileByPath(snapshot.issuePath);
			if (!(file instanceof TFile)) {
				continue;
			}

			await this.updateIssueFrontmatter(file, (frontmatter) => {
				frontmatter.symphony_runtime_status = "cancelled";
				frontmatter.symphony_last_completed_at = new Date().toISOString();
				frontmatter.symphony_last_error = "Execution interrupted by Obsidian restart";
			});

			if (effective.autoDispatchProjectTasks && effective.runnerCommandTemplate.trim()) {
				this.enqueueRetry(snapshot.issuePath, snapshot.issueTitle, "Recovered after restart", snapshot.attempt + 1);
			}
		}

		await this.persistPluginData();
	}

	private async reconcileExecution(): Promise<void> {
		if (!this.issueIndex) {
			return;
		}

		const effective = this.getEffectiveSettings();
		if (!effective.autoDispatchProjectTasks || !effective.runnerCommandTemplate.trim()) {
			return;
		}

		const availableSlots = Math.max(0, effective.maxConcurrentRuns - this.activeExecutions.size);
		if (availableSlots === 0) {
			return;
		}

		let remaining = availableSlots;
		const now = Date.now();

		for (const issue of this.issueIndex.issues) {
			if (remaining <= 0) {
				break;
			}
			if (!this.shouldDispatchIssue(issue, now)) {
				continue;
			}

			const dispatched = await this.dispatchIndexedIssue(issue);
			if (dispatched) {
				remaining -= 1;
			}
		}
	}

	private shouldDispatchIssue(issue: IndexedIssue, now: number): boolean {
		if (!issue.eligible) {
			return false;
		}
		if (this.activeExecutions.has(issue.path)) {
			return false;
		}
		if (issue.runtimeStatus === "running") {
			return false;
		}

		const retryEntry = this.retryQueue.get(issue.path);
		if (retryEntry && retryEntry.dueAt > now) {
			return false;
		}

		if (
			issue.lastDispatchedState &&
			issue.lastDispatchedState === issue.state &&
			COMPLETED_RUNTIME_STATES.has(issue.runtimeStatus) &&
			!retryEntry
		) {
			return false;
		}

		return true;
	}

	private async createSymphonyTaskNote(): Promise<void> {
		const effective = this.getEffectiveSettings();
		const taskTitle = window.prompt("Symphony task title");
		if (taskTitle === null) {
			return;
		}

		const title = taskTitle.trim();
		if (!title) {
			new Notice("Task title is required.");
			return;
		}

		const implementationPathInput = window.prompt("Implementation path", "/implementation");
		if (implementationPathInput === null) {
			return;
		}

		const implementationPath = this.normalizeImplementationPath(implementationPathInput);
		await this.ensureVaultFolder(effective.issueFolderPath);
		const filePath = await this.getAvailableIssuePath(effective.issueFolderPath, title);
		const file = await this.app.vault.create(filePath, this.buildSymphonyTaskContent(title, implementationPath));
		await this.app.workspace.getLeaf(true).openFile(file);
		await this.refreshIssueIndex();
		new Notice(`Created Symphony task ${title}.`, 5000);
	}

	private async assignCurrentNoteToSymphony(file: TFile): Promise<void> {
		const effective = this.getEffectiveSettings();
		const originalPath = file.path;
		let moved = false;
		let implementationPath = "/implementation";

		await this.ensureVaultFolder(effective.issueFolderPath);
		if (!this.isIssueFilePath(file.path, effective.issueFolderPath)) {
			const targetPath = await this.getAvailableIssuePath(effective.issueFolderPath, file.basename);
			await this.app.fileManager.renameFile(file, targetPath);
			moved = true;
		}

		await this.updateIssueFrontmatter(file, (frontmatter) => {
			this.setProjectMarker(frontmatter, effective.projectRelatedMarker, true);

			const explicitState = this.readExplicitIssueState(frontmatter);
			if (!explicitState || TERMINAL_NOTE_STATES.has(explicitState.toLowerCase())) {
				frontmatter.state = "Todo";
			}

			const instanceId = this.settings.symphonyInstanceId.trim();
			if (instanceId) {
				frontmatter.symphony_instance_id = instanceId;
			}
			const existingImplementationPath =
				typeof frontmatter.implementation_path === "string" ? frontmatter.implementation_path : "";
			implementationPath = this.normalizeImplementationPath(existingImplementationPath);
			frontmatter.implementation_path = implementationPath;
			frontmatter.symphony_assigned_at = new Date().toISOString();
			if (moved && typeof frontmatter.symphony_source_path !== "string") {
				frontmatter.symphony_source_path = originalPath;
			}
		});
		await this.ensureImplementationSection(file, implementationPath);

		await this.app.workspace.getLeaf(true).openFile(file);
		await this.refreshIssueIndex();
		const destination = moved ? ` and moved it to ${file.path}` : "";
		new Notice(`Assigned ${file.basename} to Symphony${destination}.`, 5000);
	}

	private async dispatchCurrentIssue(file: TFile): Promise<void> {
		await this.refreshIssueIndex();

		const issue = this.issueIndex?.issues.find((entry) => entry.path === file.path);
		const effective = this.getEffectiveSettings();
		if (!issue) {
			new Notice(`No Symphony issue metadata found for ${file.path}.`);
			return;
		}
		if (!issue.eligible) {
			new Notice(`Current note is not eligible for work: ${issue.title}.`);
			return;
		}
		if (!effective.runnerCommandTemplate.trim()) {
			new Notice("Set a runner command template in settings or WORKFLOW.md before dispatching work.");
			return;
		}
		if (this.activeExecutions.has(issue.path)) {
			new Notice(`Symphony is already working on ${issue.title}.`);
			return;
		}
		if (this.activeExecutions.size >= effective.maxConcurrentRuns) {
			new Notice(`Symphony is already using all ${effective.maxConcurrentRuns} execution slot(s).`);
			return;
		}

		const dispatched = await this.dispatchIndexedIssue(issue);
		if (dispatched) {
			new Notice(`Started work on ${issue.title}.`, 5000);
		}
	}

	private async stopCurrentIssue(file: TFile): Promise<void> {
		const execution = this.activeExecutions.get(file.path);
		if (!execution) {
			new Notice(`No active Symphony job for ${file.path}.`);
			return;
		}

		this.noRetryJobIds.add(execution.startResult.runningJob.id);
		await execution.startResult.cancel("Stopped from Obsidian");
		new Notice(`Stopping work on ${execution.issueTitle}.`, 5000);
	}

	private async dispatchIndexedIssue(issue: IndexedIssue): Promise<boolean> {
		const file = this.app.vault.getAbstractFileByPath(issue.path);
		if (!(file instanceof TFile)) {
			return false;
		}

		const effective = this.getEffectiveSettings();
		const retryEntry = this.retryQueue.get(issue.path);
		const attempt = retryEntry?.attempts ?? 1;
		this.retryQueue.delete(issue.path);
		this.scheduleRetryReconcile();

		const vaultPath = this.getVaultBasePath();
		const workspaceRoot = await this.ensureWorkspaceRoot(vaultPath, effective.desktopWorkspaceRoot);
		const logRoot = await this.ensureLogRoot(vaultPath, effective.desktopLogRoot);
		const jobId = `${issue.path}:${Date.now()}`;

		await this.updateIssueFrontmatter(file, (frontmatter) => {
			const currentState = this.readIssueState(frontmatter);
			let dispatchedState = currentState;
			if (currentState.toLowerCase() === "todo") {
				frontmatter.state = "In Progress";
				dispatchedState = "In Progress";
			}
			frontmatter.symphony_runtime_status = "running";
			frontmatter.symphony_last_dispatched_state = dispatchedState || issue.state;
			frontmatter.symphony_last_started_at = new Date().toISOString();
			frontmatter.symphony_retry_attempt = attempt;
			delete frontmatter.symphony_last_error;
		});

		const startResult = await this.processRunner.start(
			{
				id: jobId,
				createdAt: Date.now(),
				context: {
					issuePath: issue.path,
					issueTitle: issue.title,
					vaultPath,
					workspaceRoot,
					logRoot,
				},
				template: {
					command: effective.runnerCommandTemplate,
					shell: true,
				},
			},
			{
				workingDirectory: workspaceRoot || undefined,
				timeoutMs: effective.runnerTimeoutMs ?? undefined,
			},
		);

		this.activeExecutions.set(issue.path, {
			issuePath: issue.path,
			issueTitle: issue.title,
			attempt,
			startedAt: Date.now(),
			startResult,
		});
		await this.persistPluginData();
		this.rerenderDashboardViews();

		void startResult.completed.then((job) => this.finalizeExecution(issue.path, issue.title, job, logRoot));
		return true;
	}

	private async finalizeExecution(
		issuePath: string,
		issueTitle: string,
		job: ExecutionJob,
		logRoot: string,
	): Promise<void> {
		if (this.finalizedJobIds.has(job.id)) {
			return;
		}
		this.finalizedJobIds.add(job.id);

		const activeExecution = this.activeExecutions.get(issuePath);
		const attempt = activeExecution?.attempt ?? 1;
		this.activeExecutions.delete(issuePath);
		this.recentExecutions = [job, ...this.recentExecutions].slice(0, 20);

		const shouldRetry = this.shouldRetryJob(job);
		if (shouldRetry) {
			this.enqueueRetry(issuePath, issueTitle, summarizeExecutionJob(job).outcome, attempt + 1);
		}

		const file = this.app.vault.getAbstractFileByPath(issuePath);
		if (file instanceof TFile) {
			await this.updateIssueFrontmatter(file, (frontmatter) => {
				frontmatter.symphony_runtime_status = shouldRetry ? "retry-queued" : job.state;
				frontmatter.symphony_last_completed_at = new Date().toISOString();
				frontmatter.symphony_last_error = shouldRetry ? summarizeExecutionJob(job).outcome : "";
				frontmatter.symphony_retry_attempt = attempt;

				if ("exitCode" in job) {
					frontmatter.symphony_last_exit_code = job.exitCode;
				}

				const currentState = this.readIssueState(frontmatter);
				if (job.state === "completed" && currentState.toLowerCase() === "in progress") {
					frontmatter.state = HUMAN_REVIEW_STATE;
				}
			});
		}

		await this.writeExecutionLog(logRoot, issuePath, issueTitle, job);
		await this.persistPluginData();
		this.rerenderDashboardViews();
		this.scheduleRetryReconcile();
		await this.refreshIssueIndex();
	}

	private shouldRetryJob(job: ExecutionJob): boolean {
		if (this.isUnloading) {
			return false;
		}
		if (this.noRetryJobIds.has(job.id)) {
			return false;
		}
		return job.state === "failed" || job.state === "cancelled";
	}

	private enqueueRetry(issuePath: string, issueTitle: string, reason: string, attempts: number): void {
		const dueAt = Date.now() + calculateRetryDelay(attempts);
		this.retryQueue.set(issuePath, {
			issuePath,
			issueTitle,
			attempts,
			dueAt,
			reason,
		});
		this.scheduleRetryReconcile();
	}

	private async writeExecutionLog(
		logRoot: string,
		issuePath: string,
		issueTitle: string,
		job: ExecutionJob,
	): Promise<void> {
		if (!logRoot) {
			return;
		}

		const filename = `${this.toSafeName(issuePath)}-${Date.now()}.log`;
		const content = [
			`Issue: ${issueTitle}`,
			`Path: ${issuePath}`,
			`State: ${job.state}`,
			`Job: ${job.id}`,
			"",
			"STDOUT",
			"------",
			"stdout" in job ? job.stdout : "",
			"",
			"STDERR",
			"------",
			"stderr" in job ? job.stderr : "",
			"",
		].join("\n");

		await writeFile(join(logRoot, filename), content, "utf8");
	}

	private async ensureWorkspaceRoot(vaultPath: string, configuredRoot: string): Promise<string> {
		const root = configuredRoot.trim() || join(vaultPath || ".", ".symphony-workspaces");
		await mkdir(root, { recursive: true });
		return root;
	}

	private async ensureLogRoot(vaultPath: string, configuredRoot: string): Promise<string> {
		const root = configuredRoot.trim() || join(vaultPath || ".", ".symphony-logs");
		await mkdir(root, { recursive: true });
		return root;
	}

	private getVaultBasePath(): string {
		const adapter = this.app.vault.adapter as { getBasePath?: () => string };
		return typeof adapter.getBasePath === "function" ? adapter.getBasePath() : "";
	}

	private async updateIssueFrontmatter(
		file: TFile,
		mutate: (frontmatter: Record<string, unknown>) => void,
	): Promise<void> {
		await this.app.fileManager.processFrontMatter(file, (frontmatter) => {
			const mutableFrontmatter = frontmatter as Record<string, unknown>;
			mutate(mutableFrontmatter);
			syncTaskPluginMetadata(mutableFrontmatter, this.readIssueState(mutableFrontmatter));
		});
	}

	private buildSymphonyTaskContent(title: string, implementationPath: string): string {
		const marker = this.getEffectiveSettings().projectRelatedMarker;
		const now = new Date().toISOString();
		const lines = [
			"---",
			`title: ${this.toYamlString(title)}`,
			"state: Todo",
			`status: ${this.toYamlString(issueStateToTaskPluginStatus("Todo"))}`,
			"tags:",
			`  - ${this.toYamlString(TASK_PLUGIN_TAG)}`,
			`implementation_path: ${this.toYamlString(implementationPath)}`,
			`symphony_created_at: ${this.toYamlString(now)}`,
			`dateCreated: ${this.toYamlString(now)}`,
			`dateModified: ${this.toYamlString(now)}`,
			`${marker}: true`,
		];

		const instanceId = this.settings.symphonyInstanceId.trim();
		if (instanceId) {
			lines.push(`symphony_instance_id: ${this.toYamlString(instanceId)}`);
		}

		lines.push(
			"---",
			"",
			`# ${title}`,
			"",
			"## Objective",
			"",
			"## Context",
			"",
			"## Implementation",
			"",
			`Path: ${implementationPath}`,
			"",
			"## Definition of done",
			"",
		);
		return lines.join("\n");
	}

	private async ensureVaultFolder(folderPath: string): Promise<void> {
		const normalizedFolderPath = normalizePath(folderPath);
		if (!normalizedFolderPath) {
			return;
		}

		const segments = normalizedFolderPath.split("/").filter(Boolean);
		let currentPath = "";
		for (const segment of segments) {
			currentPath = currentPath ? `${currentPath}/${segment}` : segment;
			if (!this.app.vault.getAbstractFileByPath(currentPath)) {
				await this.app.vault.createFolder(currentPath);
			}
		}
	}

	private async getAvailableIssuePath(issueFolderPath: string, title: string): Promise<string> {
		const baseName = `${this.toTimestampPrefix()}-${this.toSafeName(title).toLowerCase() || "task"}`;
		let suffix = 0;

		for (;;) {
			const filename = suffix === 0 ? `${baseName}.md` : `${baseName}-${suffix + 1}.md`;
			const candidatePath = normalizePath(`${issueFolderPath}/${filename}`);
			if (!this.app.vault.getAbstractFileByPath(candidatePath)) {
				return candidatePath;
			}
			suffix += 1;
		}
	}

	private async ensureImplementationSection(file: TFile, implementationPath: string): Promise<void> {
		const content = await this.app.vault.read(file);
		const normalizedPathLine = `Path: ${implementationPath}`;
		const implementationSection = this.findImplementationSection(content);

		if (implementationSection) {
			const sectionContent = content.slice(implementationSection.start, implementationSection.end);
			let updatedSection = sectionContent;

			if (/^Path:\s+.*$/im.test(sectionContent)) {
				updatedSection = sectionContent.replace(/^Path:\s+.*$/im, normalizedPathLine);
			} else {
				updatedSection = sectionContent.replace(
					/^## Implementation\s*$/im,
					`## Implementation\n\n${normalizedPathLine}`,
				);
			}

			if (updatedSection !== sectionContent) {
				const updatedContent =
					content.slice(0, implementationSection.start) +
					updatedSection +
					content.slice(implementationSection.end);
				await this.app.vault.modify(file, updatedContent);
			}
			return;
		}

		const trimmed = content.replace(/\s*$/, "");
		const separator = trimmed.length > 0 ? "\n\n" : "";
		const updated = `${trimmed}${separator}## Implementation\n\n${normalizedPathLine}\n`;
		await this.app.vault.modify(file, updated);
	}

	private isIssueFilePath(filePath: string, issueFolderPath: string): boolean {
		const normalizedFilePath = normalizePath(filePath);
		const normalizedIssueFolder = normalizePath(issueFolderPath);
		return normalizedFilePath.startsWith(`${normalizedIssueFolder}/`);
	}

	private setProjectMarker(frontmatter: Record<string, unknown>, marker: string, value: boolean): void {
		frontmatter[marker] = value;
	}

	private readExplicitIssueState(frontmatter: Record<string, unknown>): string {
		const rawState = typeof frontmatter.state === "string" ? frontmatter.state.trim() : "";
		const rawStatus = typeof frontmatter.status === "string" ? frontmatter.status.trim() : "";
		return normalizeSymphonyIssueState(rawState || rawStatus);
	}

	private readIssueState(frontmatter: Record<string, unknown>): string {
		return this.readExplicitIssueState(frontmatter) || "Todo";
	}

	private toSafeName(value: string): string {
		return value.replace(/[<>:"/\\|?*]+/g, "_").replace(/\s+/g, "-");
	}

	private toTimestampPrefix(): string {
		return new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "");
	}

	private toYamlString(value: string): string {
		return JSON.stringify(value);
	}

	private normalizeImplementationPath(value: string): string {
		const trimmed = value.trim();
		if (!trimmed) {
			return "/implementation";
		}

		const normalized = trimmed.replace(/\\/g, "/").replace(/\/{2,}/g, "/");
		return normalized.startsWith("/") ? normalized : `/${normalized}`;
	}

	private findImplementationSection(content: string): { start: number; end: number } | null {
		const headingPattern = /^##\s+Implementation\s*$/im;
		const match = headingPattern.exec(content);
		if (!match || match.index === undefined) {
			return null;
		}

		const start = match.index;
		const afterHeadingIndex = start + match[0].length;
		const remainingContent = content.slice(afterHeadingIndex);
		const nextHeadingMatch = /^\s*##\s+/m.exec(remainingContent);
		const end = nextHeadingMatch && nextHeadingMatch.index !== undefined
			? afterHeadingIndex + nextHeadingMatch.index
			: content.length;

		return { start, end };
	}

	private async activateDashboardView(): Promise<void> {
		const { workspace } = this.app;
		let leaf: WorkspaceLeaf | null = workspace.getLeavesOfType(SYMPHONY_DASHBOARD_VIEW_TYPE)[0] ?? null;

		if (!leaf) {
			leaf = workspace.getRightLeaf(false);
			if (!leaf) {
				new Notice("Unable to create a Symphony dashboard leaf.");
				return;
			}
			await leaf.setViewState({
				type: SYMPHONY_DASHBOARD_VIEW_TYPE,
				active: true,
			});
		}

		await workspace.revealLeaf(leaf);

		if (leaf.view instanceof SymphonyDashboardView) {
			leaf.view.render();
		}
	}
}

class SymphonySettingTab extends PluginSettingTab {
	constructor(app: App, private readonly plugin: SymphonyPlugin) {
		super(app, plugin);
	}

	display(): void {
		const { containerEl } = this;
		containerEl.empty();

		containerEl.createEl("h2", { text: "Symphony" });
		containerEl.createEl("p", {
			text: "Local settings provide defaults and host-specific overrides. Put shared execution policy in WORKFLOW.md.",
		});

		new Setting(containerEl)
			.setName("Issue folder path")
			.setDesc("Fallback issue folder when WORKFLOW.md does not override it.")
			.addText((text) =>
				text
					.setPlaceholder(DEFAULT_SETTINGS.issueFolderPath)
					.setValue(this.plugin.settings.issueFolderPath)
					.onChange(async (value) => {
						this.plugin.settings.issueFolderPath = value.trim() || DEFAULT_SETTINGS.issueFolderPath;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Project-related marker")
			.setDesc("Fallback note marker when WORKFLOW.md does not override it.")
			.addText((text) =>
				text
					.setPlaceholder(DEFAULT_SETTINGS.projectRelatedMarker)
					.setValue(this.plugin.settings.projectRelatedMarker)
					.onChange(async (value) => {
						this.plugin.settings.projectRelatedMarker = value.trim() || DEFAULT_SETTINGS.projectRelatedMarker;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Symphony instance ID")
			.setDesc("Per-vault Symphony instance identifier stamped onto created and assigned tasks.")
			.addText((text) =>
				text
					.setPlaceholder("ee6b817756f5639c")
					.setValue(this.plugin.settings.symphonyInstanceId)
					.onChange(async (value) => {
						this.plugin.settings.symphonyInstanceId = value.trim();
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Runner command template")
			.setDesc("Local fallback runner when WORKFLOW.md does not define one.")
			.addTextArea((text) =>
				text
					.setPlaceholder("codex exec \"Work on {{issue_path}}\"")
					.setValue(this.plugin.settings.runnerCommandTemplate)
					.onChange(async (value) => {
						this.plugin.settings.runnerCommandTemplate = value.trim();
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Auto-dispatch project tasks")
			.setDesc("Local fallback for auto-dispatch when WORKFLOW.md does not define it.")
			.addToggle((toggle) =>
				toggle
					.setValue(this.plugin.settings.autoDispatchProjectTasks)
					.onChange(async (value) => {
						this.plugin.settings.autoDispatchProjectTasks = value;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Max concurrent runs")
			.setDesc("Local fallback concurrency limit when WORKFLOW.md does not define it.")
			.addText((text) =>
				text
					.setPlaceholder(String(DEFAULT_SETTINGS.maxConcurrentRuns))
					.setValue(String(this.plugin.settings.maxConcurrentRuns))
					.onChange(async (value) => {
						this.plugin.settings.maxConcurrentRuns = Number.parseInt(value.trim(), 10) || DEFAULT_SETTINGS.maxConcurrentRuns;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Runner timeout (ms)")
			.setDesc("Local fallback timeout when WORKFLOW.md does not define one.")
			.addText((text) =>
				text
					.setPlaceholder("600000")
					.setValue(this.plugin.settings.runnerTimeoutMs === null ? "" : String(this.plugin.settings.runnerTimeoutMs))
					.onChange(async (value) => {
						const trimmed = value.trim();
						this.plugin.settings.runnerTimeoutMs = trimmed ? Number.parseInt(trimmed, 10) || null : null;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Workflow file path")
			.setDesc("Vault-relative WORKFLOW.md path used to load shared execution policy.")
			.addText((text) =>
				text
					.setPlaceholder(DEFAULT_SETTINGS.workflowFilePath)
					.setValue(this.plugin.settings.workflowFilePath)
					.onChange(async (value) => {
						this.plugin.settings.workflowFilePath = value.trim() || DEFAULT_SETTINGS.workflowFilePath;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Desktop workspace root")
			.setDesc("Host-local workspace root. Shared policy should usually leave this unset.")
			.addText((text) =>
				text
					.setPlaceholder("C:\\work\\symphony")
					.setValue(this.plugin.settings.desktopWorkspaceRoot)
					.onChange(async (value) => {
						this.plugin.settings.desktopWorkspaceRoot = value.trim();
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Desktop log root")
			.setDesc("Host-local log root. Shared policy should usually leave this unset.")
			.addText((text) =>
				text
					.setPlaceholder("C:\\work\\symphony-logs")
					.setValue(this.plugin.settings.desktopLogRoot)
					.onChange(async (value) => {
						this.plugin.settings.desktopLogRoot = value.trim();
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Auto start")
			.setDesc("Enable runtime behavior after layout is ready.")
			.addToggle((toggle) =>
				toggle
					.setValue(this.plugin.settings.autoStart)
					.onChange(async (value) => {
						this.plugin.settings.autoStart = value;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Open dashboard on start")
			.setDesc("Reveal the Symphony dashboard after layout is ready.")
			.addToggle((toggle) =>
				toggle
					.setValue(this.plugin.settings.dashboardOpenOnStart)
					.onChange(async (value) => {
						this.plugin.settings.dashboardOpenOnStart = value;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("HTTP port override")
			.setDesc("Optional loopback port reserved for a future local HTTP API.")
			.addText((text) =>
				text
					.setPlaceholder("3000")
					.setValue(this.plugin.settings.httpPortOverride === null ? "" : String(this.plugin.settings.httpPortOverride))
					.onChange(async (value) => {
						const trimmed = value.trim();
						this.plugin.settings.httpPortOverride = trimmed ? Number.parseInt(trimmed, 10) || null : null;
						await this.plugin.saveSettings();
					}),
			);

		new Setting(containerEl)
			.setName("Allow workspace inside vault")
			.setDesc("Unsafe by default. Leave disabled unless the runtime explicitly supports it.")
			.addToggle((toggle) =>
				toggle
					.setValue(this.plugin.settings.allowWorkspaceInsideVault)
					.onChange(async (value) => {
						this.plugin.settings.allowWorkspaceInsideVault = value;
						await this.plugin.saveSettings();
					}),
			);
	}
}

function calculateRetryDelay(attempt: number): number {
	return Math.min(RETRY_MAX_DELAY_MS, RETRY_BASE_DELAY_MS * 2 ** Math.max(0, attempt - 1));
}

function limitExecutionJobs(jobs: unknown): ExecutionJob[] {
	return Array.isArray(jobs) ? (jobs as ExecutionJob[]).slice(0, 20) : [];
}

function isRetryEntry(value: unknown): value is RetryEntry {
	if (typeof value !== "object" || value === null) {
		return false;
	}

	const record = value as Record<string, unknown>;
	return (
		typeof record.issuePath === "string" &&
		typeof record.issueTitle === "string" &&
		typeof record.attempts === "number" &&
		typeof record.dueAt === "number" &&
		typeof record.reason === "string"
	);
}

function isPersistedPluginData(value: unknown): value is PersistedPluginData {
	if (typeof value !== "object" || value === null) {
		return false;
	}

	const record = value as Record<string, unknown>;
	return "settings" in record && "runtime" in record;
}
