import type { CachedMetadata, FrontMatterCache, TFile, Vault } from "obsidian";
import { normalizePath } from "obsidian";
import type { SymphonySettings } from "./settings";

export interface IndexedIssue {
	path: string;
	title: string;
	state: string;
	projectRelated: boolean;
	eligible: boolean;
	runtimeStatus: string;
	lastDispatchedState: string;
	reasons: string[];
}

export interface IssueIndexSnapshot {
	scannedAt: number;
	issueFolderPath: string;
	totalMarkdownFiles: number;
	projectRelatedCount: number;
	eligibleCount: number;
	issues: IndexedIssue[];
}

const TERMINAL_STATES = new Set(["done", "closed", "cancelled", "canceled", "archive", "archived"]);
const ACTIVE_STATES = new Set(["todo", "in progress", "queued", "pending", "retry"]);

export function buildIssueIndex(
	vault: Vault,
	settings: SymphonySettings,
	getCache: (file: TFile) => CachedMetadata | null,
): IssueIndexSnapshot {
	const issueFolderPath = normalizePath(settings.issueFolderPath);
	const marker = normalizeMarker(settings.projectRelatedMarker);

	const issues = vault
		.getMarkdownFiles()
		.filter((file) => isInIssueFolder(file.path, issueFolderPath))
		.map((file) => buildIndexedIssue(file, getCache(file), marker))
		.sort((left, right) => left.path.localeCompare(right.path));

	return {
		scannedAt: Date.now(),
		issueFolderPath,
		totalMarkdownFiles: issues.length,
		projectRelatedCount: issues.filter((issue) => issue.projectRelated).length,
		eligibleCount: issues.filter((issue) => issue.eligible).length,
		issues,
	};
}

function buildIndexedIssue(file: TFile, cache: CachedMetadata | null, marker: string): IndexedIssue {
	const frontmatter = cache?.frontmatter ?? null;
	const title = readTitle(file, frontmatter);
	const state = readState(frontmatter);
	const reasons: string[] = [];
	const projectRelated = readProjectRelated(file.path, cache, frontmatter, marker, reasons);
	const runtimeStatus = readString(frontmatter?.symphony_runtime_status) || "idle";
	const lastDispatchedState = readString(frontmatter?.symphony_last_dispatched_state);
	const normalizedState = state.toLowerCase();
	const eligible = projectRelated && ACTIVE_STATES.has(normalizedState) && !TERMINAL_STATES.has(normalizedState);

	if (!projectRelated) {
		reasons.push("not project-related");
	} else if (eligible) {
		reasons.push("eligible for work");
	} else {
		reasons.push(`terminal state: ${state}`);
	}

	return {
		path: file.path,
		title,
		state,
		projectRelated,
		eligible,
		runtimeStatus,
		lastDispatchedState,
		reasons,
	};
}

function readTitle(file: TFile, frontmatter: FrontMatterCache | null): string {
	const frontmatterTitle = readString(frontmatter?.title);
	return frontmatterTitle || file.basename;
}

function readState(frontmatter: FrontMatterCache | null): string {
	return (
		readString(frontmatter?.state) ||
		readString(frontmatter?.status) ||
		"Todo"
	);
}

function readProjectRelated(
	filePath: string,
	cache: CachedMetadata | null,
	frontmatter: FrontMatterCache | null,
	marker: string,
	reasons: string[],
): boolean {
	const frontmatterValue = findFrontmatterValue(frontmatter, marker);
	if (typeof frontmatterValue === "boolean") {
		reasons.push(`frontmatter ${marker}=${frontmatterValue}`);
		return frontmatterValue;
	}

	if (typeof frontmatterValue === "string") {
		const normalized = frontmatterValue.trim().toLowerCase();
		if (["true", "yes", "1", "project"].includes(normalized)) {
			reasons.push(`frontmatter ${marker}=${frontmatterValue}`);
			return true;
		}
		if (["false", "no", "0"].includes(normalized)) {
			reasons.push(`frontmatter ${marker}=${frontmatterValue}`);
			return false;
		}
	}

	const tagValues = cache?.tags?.map((tag) => normalizeMarker(tag.tag)) ?? [];
	if (tagValues.includes(marker)) {
		reasons.push(`tag ${marker}`);
		return true;
	}

	reasons.push(`inside issue folder: ${filePath}`);
	return true;
}

function findFrontmatterValue(frontmatter: FrontMatterCache | null, marker: string): unknown {
	if (!frontmatter) {
		return null;
	}

	for (const [key, value] of Object.entries(frontmatter)) {
		if (normalizeMarker(key) === marker) {
			return value;
		}
	}

	return null;
}

function readString(value: unknown): string {
	return typeof value === "string" ? value.trim() : "";
}

function isInIssueFolder(filePath: string, issueFolderPath: string): boolean {
	return filePath === issueFolderPath || filePath.startsWith(`${issueFolderPath}/`);
}

function normalizeMarker(value: string): string {
	return value.trim().toLowerCase().replace(/^#/, "");
}
