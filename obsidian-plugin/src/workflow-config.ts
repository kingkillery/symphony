import type { CachedMetadata, FrontMatterCache, MetadataCache, TFile, Vault } from "obsidian";
import { normalizePath } from "obsidian";
import type { SymphonySettings } from "./settings";

export interface WorkflowRuntimeOverrides {
	issueFolderPath?: string;
	projectRelatedMarker?: string;
	runnerCommandTemplate?: string;
	autoDispatchProjectTasks?: boolean;
	maxConcurrentRuns?: number;
	runnerTimeoutMs?: number | null;
	desktopWorkspaceRoot?: string;
	desktopLogRoot?: string;
}

export interface WorkflowConfigSnapshot {
	path: string;
	found: boolean;
	loadedAt: number;
	overrides: WorkflowRuntimeOverrides;
	errors: string[];
}

export const EMPTY_WORKFLOW_CONFIG: WorkflowConfigSnapshot = {
	path: "",
	found: false,
	loadedAt: 0,
	overrides: {},
	errors: [],
};

export function loadWorkflowConfig(
	vault: Vault,
	metadataCache: MetadataCache,
	workflowFilePath: string,
): WorkflowConfigSnapshot {
	const path = normalizePath(workflowFilePath);
	const file = vault.getAbstractFileByPath(path);
	if (!file || !(file instanceof TFile)) {
		return {
			path,
			found: false,
			loadedAt: Date.now(),
			overrides: {},
			errors: [`Missing workflow file: ${path}`],
		};
	}

	const cache = metadataCache.getFileCache(file);
	const frontmatter = cache?.frontmatter ?? null;
	const overrides = readOverrides(frontmatter);

	return {
		path,
		found: true,
		loadedAt: Date.now(),
		overrides,
		errors: [],
	};
}

export function mergeSettingsWithWorkflow(
	settings: SymphonySettings,
	workflow: WorkflowConfigSnapshot,
): SymphonySettings {
	const overrides = workflow.overrides;
	return {
		...settings,
		issueFolderPath: normalizePath(overrides.issueFolderPath ?? settings.issueFolderPath),
		projectRelatedMarker: overrides.projectRelatedMarker ?? settings.projectRelatedMarker,
		runnerCommandTemplate: overrides.runnerCommandTemplate ?? settings.runnerCommandTemplate,
		autoDispatchProjectTasks: overrides.autoDispatchProjectTasks ?? settings.autoDispatchProjectTasks,
		maxConcurrentRuns: overrides.maxConcurrentRuns ?? settings.maxConcurrentRuns,
		runnerTimeoutMs: overrides.runnerTimeoutMs ?? settings.runnerTimeoutMs,
		desktopWorkspaceRoot: overrides.desktopWorkspaceRoot ?? settings.desktopWorkspaceRoot,
		desktopLogRoot: overrides.desktopLogRoot ?? settings.desktopLogRoot,
	};
}

function readOverrides(frontmatter: FrontMatterCache | null): WorkflowRuntimeOverrides {
	if (!frontmatter) {
		return {};
	}

	const pluginSection = findSection(frontmatter, ["obsidian_plugin", "obsidianPlugin", "plugin", "obsidian"]);
	return {
		issueFolderPath: readString(findValue(pluginSection, frontmatter, ["issue_folder_path", "issueFolderPath"])),
		projectRelatedMarker: readString(findValue(pluginSection, frontmatter, ["project_related_marker", "projectRelatedMarker"])),
		runnerCommandTemplate: readString(findValue(pluginSection, frontmatter, ["runner_command_template", "runnerCommandTemplate"])),
		autoDispatchProjectTasks: readBoolean(findValue(pluginSection, frontmatter, ["auto_dispatch_project_tasks", "autoDispatchProjectTasks"])),
		maxConcurrentRuns: readNumber(findValue(pluginSection, frontmatter, ["max_concurrent_runs", "maxConcurrentRuns"])),
		runnerTimeoutMs: readNullableNumber(findValue(pluginSection, frontmatter, ["runner_timeout_ms", "runnerTimeoutMs"])),
		desktopWorkspaceRoot: readString(findValue(pluginSection, frontmatter, ["desktop_workspace_root", "desktopWorkspaceRoot"])),
		desktopLogRoot: readString(findValue(pluginSection, frontmatter, ["desktop_log_root", "desktopLogRoot"])),
	};
}

function findSection(frontmatter: FrontMatterCache, keys: string[]): Record<string, unknown> | null {
	for (const [key, value] of Object.entries(frontmatter)) {
		if (keys.includes(key) && isRecord(value)) {
			return value;
		}
	}

	return null;
}

function findValue(
	section: Record<string, unknown> | null,
	frontmatter: FrontMatterCache,
	keys: string[],
): unknown {
	if (section) {
		for (const key of keys) {
			if (key in section) {
				return section[key];
			}
		}
	}

	for (const key of keys) {
		if (key in frontmatter) {
			return frontmatter[key];
		}
	}

	return undefined;
}

function readString(value: unknown): string | undefined {
	if (typeof value !== "string") {
		return undefined;
	}

	const trimmed = value.trim();
	return trimmed ? trimmed : undefined;
}

function readBoolean(value: unknown): boolean | undefined {
	if (typeof value === "boolean") {
		return value;
	}
	if (typeof value === "string") {
		const normalized = value.trim().toLowerCase();
		if (["true", "yes", "1", "on"].includes(normalized)) {
			return true;
		}
		if (["false", "no", "0", "off"].includes(normalized)) {
			return false;
		}
	}

	return undefined;
}

function readNumber(value: unknown): number | undefined {
	if (typeof value === "number" && Number.isFinite(value)) {
		return value;
	}
	if (typeof value === "string") {
		const parsed = Number.parseInt(value.trim(), 10);
		return Number.isFinite(parsed) ? parsed : undefined;
	}

	return undefined;
}

function readNullableNumber(value: unknown): number | null | undefined {
	if (value === null) {
		return null;
	}
	return readNumber(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
