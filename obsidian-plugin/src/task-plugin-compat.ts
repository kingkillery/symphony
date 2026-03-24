export const TASK_PLUGIN_TAG = "task";
export const TASK_PLUGIN_OPEN_STATUS = "open";
export const TASK_PLUGIN_DONE_STATUS = "done";

const OPEN_STATE_ALIASES = new Set([
	"todo",
	"open",
	"scheduled",
	"queued",
	"pending",
	"retry",
]);

const IN_PROGRESS_STATE_ALIASES = new Set([
	"in progress",
	"in-progress",
	"doing",
	"active",
]);

const REVIEW_STATE_ALIASES = new Set([
	"human review",
	"review",
	"awaiting review",
]);

const DONE_STATE_ALIASES = new Set([
	"done",
	"completed",
	"complete",
]);

const CLOSED_STATE_ALIASES = new Set(["closed"]);
const CANCELLED_STATE_ALIASES = new Set(["cancelled", "canceled"]);
const ARCHIVED_STATE_ALIASES = new Set(["archive", "archived"]);

export function normalizeSymphonyIssueState(value: unknown): string {
	if (typeof value !== "string") {
		return "";
	}

	const trimmed = value.trim();
	if (!trimmed) {
		return "";
	}

	const normalized = trimmed.toLowerCase();
	if (OPEN_STATE_ALIASES.has(normalized)) {
		return "Todo";
	}
	if (IN_PROGRESS_STATE_ALIASES.has(normalized)) {
		return "In Progress";
	}
	if (REVIEW_STATE_ALIASES.has(normalized)) {
		return "Human Review";
	}
	if (DONE_STATE_ALIASES.has(normalized)) {
		return "Done";
	}
	if (CLOSED_STATE_ALIASES.has(normalized)) {
		return "Closed";
	}
	if (CANCELLED_STATE_ALIASES.has(normalized)) {
		return "Cancelled";
	}
	if (ARCHIVED_STATE_ALIASES.has(normalized)) {
		return "Archived";
	}

	return trimmed;
}

export function issueStateToTaskPluginStatus(value: string): string {
	const normalizedState = normalizeSymphonyIssueState(value).toLowerCase();
	if (
		normalizedState === "done" ||
		normalizedState === "closed" ||
		normalizedState === "cancelled" ||
		normalizedState === "archived"
	) {
		return TASK_PLUGIN_DONE_STATUS;
	}

	return TASK_PLUGIN_OPEN_STATUS;
}

export function syncTaskPluginMetadata(
	frontmatter: Record<string, unknown>,
	issueState: string,
	options: { setDateCreated?: boolean } = {},
): void {
	const now = new Date().toISOString();
	const normalizedState = normalizeSymphonyIssueState(issueState) || "Todo";

	frontmatter.state = normalizedState;
	frontmatter.status = issueStateToTaskPluginStatus(normalizedState);
	frontmatter.dateModified = now;

	if (options.setDateCreated && typeof frontmatter.dateCreated !== "string") {
		frontmatter.dateCreated = now;
	}

	ensureTaskPluginTag(frontmatter);
}

function ensureTaskPluginTag(frontmatter: Record<string, unknown>): void {
	const tags = normalizeTags(frontmatter.tags);
	if (!tags.includes(TASK_PLUGIN_TAG)) {
		tags.push(TASK_PLUGIN_TAG);
	}
	frontmatter.tags = tags;
}

function normalizeTags(value: unknown): string[] {
	if (Array.isArray(value)) {
		return value.filter((tag): tag is string => typeof tag === "string" && tag.trim().length > 0);
	}
	if (typeof value === "string" && value.trim()) {
		return [value.trim()];
	}
	return [];
}
