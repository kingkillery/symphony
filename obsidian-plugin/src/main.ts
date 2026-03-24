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
	SYMPHONY_DASHBOARD_VIEW_TYPE,
	SymphonyDashboardView,
} from "./ui/symphony-dashboard-view";

interface ActiveExecution {
	issuePath: string;
	issueTitle: string;
	startedAt: number;
	startResult: ExecutionStartResult;
}

const COMPLETED_RUNTIME_STATES = new Set(["completed", "failed", "cancelled"]);
const HUMAN_REVIEW_STATE = "Human Review";

export default class SymphonyPlugin extends Plugin {
	settings: SymphonySettings = DEFAULT_SETTINGS;
	private issueIndex: IssueIndexSnapshot | null = null;
	private refreshTimeout: number | null = null;
	private readonly processRunner = new NodeExecutionProcessRunner();
	private readonly activeExecutions = new Map<string, ActiveExecution>();
	private recentExecutions: ExecutionJob[] = [];
	private readonly finalizedJobIds = new Set<string>();

	async onload(): Promise<void> {
		await this.loadSettings();
		this.registerView(
			SYMPHONY_DASHBOARD_VIEW_TYPE,
			(leaf) =>
				new SymphonyDashboardView(
					leaf,
					() => this.settings,
					() => this.issueIndex,
					() => this.getExecutionSummaries(),
				),
		);

		this.addSettingTab(new SymphonySettingTab(this.app, this));
		this.registerCommands();
		this.registerVaultEvents();

		this.app.workspace.onLayoutReady(() => {
			void this.refreshIssueIndex();

			if (this.settings.dashboardOpenOnStart) {
				void this.activateDashboardView();
			}

			if (this.settings.autoStart) {
				new Notice("Symphony runtime loaded. Project-related Obsidian tasks will dispatch when eligible.", 7000);
			}
		});
	}

	async onunload(): Promise<void> {
		if (this.refreshTimeout !== null) {
			window.clearTimeout(this.refreshTimeout);
		}

		await Promise.all(
			Array.from(this.activeExecutions.values(), (execution) => execution.startResult.cancel("Plugin unloaded")),
		);

		await this.app.workspace.detachLeavesOfType(SYMPHONY_DASHBOARD_VIEW_TYPE);
	}

	async loadSettings(): Promise<void> {
		this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
		this.normalizeSettings();
	}

	async saveSettings(): Promise<void> {
		this.normalizeSettings();
		await this.saveData(this.settings);
		await this.refreshIssueIndex();
		this.rerenderDashboardViews();
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

	private normalizeSettings(): void {
		this.settings.issueFolderPath = normalizePath(this.settings.issueFolderPath);
		this.settings.workflowFilePath = normalizePath(this.settings.workflowFilePath);
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
				this.scheduleIssueIndexRefresh();
			}
		};

		this.registerEvent(this.app.vault.on("create", (file) => refresh(file)));
		this.registerEvent(this.app.vault.on("modify", (file) => refresh(file)));
		this.registerEvent(this.app.vault.on("delete", (file) => refresh(file)));
		this.registerEvent(this.app.vault.on("rename", (file, oldPath) => {
			if (this.shouldRefreshForFile(oldPath)) {
				this.scheduleIssueIndexRefresh();
				return;
			}
			refresh(file);
		}));
		this.registerEvent(this.app.metadataCache.on("changed", (file) => refresh(file)));
	}

	private shouldRefreshForFile(path: string): boolean {
		const normalizedPath = normalizePath(path);
		const issueFolder = this.settings.issueFolderPath;
		return normalizedPath.endsWith(".md") && normalizedPath.startsWith(`${issueFolder}/`);
	}

	private scheduleIssueIndexRefresh(): void {
		if (this.refreshTimeout !== null) {
			window.clearTimeout(this.refreshTimeout);
		}

		this.refreshTimeout = window.setTimeout(() => {
			this.refreshTimeout = null;
			void this.refreshIssueIndex();
		}, 200);
	}

	private async refreshIssueIndex(): Promise<IssueIndexSnapshot> {
		this.issueIndex = buildIssueIndex(
			this.app.vault,
			this.settings,
			(file) => this.app.metadataCache.getFileCache(file),
		);
		this.rerenderDashboardViews();
		await this.reconcileExecution();
		return this.issueIndex;
	}

	private async reconcileExecution(): Promise<void> {
		if (!this.issueIndex) {
			return;
		}
		if (!this.settings.autoDispatchProjectTasks) {
			return;
		}
		if (!this.settings.runnerCommandTemplate.trim()) {
			return;
		}

		const availableSlots = Math.max(0, this.settings.maxConcurrentRuns - this.activeExecutions.size);
		if (availableSlots === 0) {
			return;
		}

		let remaining = availableSlots;
		for (const issue of this.issueIndex.issues) {
			if (remaining <= 0) {
				break;
			}
			if (!this.shouldDispatchIssue(issue)) {
				continue;
			}

			const dispatched = await this.dispatchIndexedIssue(issue);
			if (dispatched) {
				remaining -= 1;
			}
		}
	}

	private shouldDispatchIssue(issue: IndexedIssue): boolean {
		if (!issue.eligible) {
			return false;
		}
		if (this.activeExecutions.has(issue.path)) {
			return false;
		}
		if (issue.runtimeStatus === "running") {
			return false;
		}
		if (
			issue.lastDispatchedState &&
			issue.lastDispatchedState === issue.state &&
			COMPLETED_RUNTIME_STATES.has(issue.runtimeStatus)
		) {
			return false;
		}
		return true;
	}

	private async dispatchCurrentIssue(file: TFile): Promise<void> {
		await this.refreshIssueIndex();

		const issue = this.issueIndex?.issues.find((entry) => entry.path === file.path);
		if (!issue) {
			new Notice(`No Symphony issue metadata found for ${file.path}.`);
			return;
		}
		if (!issue.eligible) {
			new Notice(`Current note is not eligible for work: ${issue.title}.`);
			return;
		}
		if (!this.settings.runnerCommandTemplate.trim()) {
			new Notice("Set a runner command template before dispatching work.");
			return;
		}
		if (this.activeExecutions.has(issue.path)) {
			new Notice(`Symphony is already working on ${issue.title}.`);
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

		await execution.startResult.cancel("Stopped from Obsidian");
		new Notice(`Stopping work on ${execution.issueTitle}.`, 5000);
	}

	private async dispatchIndexedIssue(issue: IndexedIssue): Promise<boolean> {
		const file = this.app.vault.getAbstractFileByPath(issue.path);
		if (!(file instanceof TFile)) {
			return false;
		}

		const vaultPath = this.getVaultBasePath();
		const workspaceRoot = await this.ensureWorkspaceRoot(vaultPath);
		const logRoot = await this.ensureLogRoot(vaultPath);
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
					command: this.settings.runnerCommandTemplate,
					shell: true,
				},
			},
			{
				workingDirectory: workspaceRoot || undefined,
				timeoutMs: this.settings.runnerTimeoutMs ?? undefined,
			},
		);

		this.activeExecutions.set(issue.path, {
			issuePath: issue.path,
			issueTitle: issue.title,
			startedAt: Date.now(),
			startResult,
		});
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
		this.activeExecutions.delete(issuePath);
		this.recentExecutions = [job, ...this.recentExecutions].slice(0, 20);

		const file = this.app.vault.getAbstractFileByPath(issuePath);
		if (file instanceof TFile) {
			await this.updateIssueFrontmatter(file, (frontmatter) => {
				frontmatter.symphony_runtime_status = job.state;
				frontmatter.symphony_last_completed_at = new Date().toISOString();

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
		this.rerenderDashboardViews();
		await this.refreshIssueIndex();
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

	private async ensureWorkspaceRoot(vaultPath: string): Promise<string> {
		const root = this.settings.desktopWorkspaceRoot.trim() || join(vaultPath || ".", ".symphony-workspaces");
		await mkdir(root, { recursive: true });
		return root;
	}

	private async ensureLogRoot(vaultPath: string): Promise<string> {
		const root = this.settings.desktopLogRoot.trim() || join(vaultPath || ".", ".symphony-logs");
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
			mutate(frontmatter as Record<string, unknown>);
		});
	}

	private readIssueState(frontmatter: Record<string, unknown>): string {
		const state = typeof frontmatter.state === "string" ? frontmatter.state.trim() : "";
		const status = typeof frontmatter.status === "string" ? frontmatter.status.trim() : "";
		return state || status || "Todo";
	}

	private toSafeName(value: string): string {
		return value.replace(/[<>:"/\\|?*]+/g, "_");
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
			text: "This settings tab configures the execution layer for project-related Obsidian work.",
		});

		new Setting(containerEl)
			.setName("Issue folder path")
			.setDesc("Vault-relative folder where Symphony should look for project-related task notes.")
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
			.setDesc("Frontmatter key or tag used to mark a note as work Symphony should pick up.")
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
			.setName("Runner command template")
			.setDesc("Shell command used to work on an issue. Supports {{issue_path}}, {{issue_title}}, {{vault_path}}, {{workspace_root}}, and {{log_root}}.")
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
			.setDesc("Automatically start eligible issue notes when refresh or vault events detect them.")
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
			.setDesc("Maximum number of issue jobs Symphony should run at once.")
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
			.setDesc("Optional timeout for a single issue run.")
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
			.setDesc("Vault-relative path to the workflow definition.")
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
			.setDesc("Absolute desktop path for per-issue workspaces. Defaults to a local .symphony-workspaces folder when blank.")
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
			.setDesc("Absolute desktop path for execution logs. Defaults to a local .symphony-logs folder when blank.")
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
			.setDesc("Reveal the Symphony dashboard after the workspace layout is ready.")
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
			.setDesc("Optional loopback port for a future local HTTP API.")
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
