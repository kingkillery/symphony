import { ItemView, WorkspaceLeaf } from "obsidian";
import type { ExecutionJobSummary } from "../execution-layer";
import type { IssueIndexSnapshot } from "../issue-index";
import type { SymphonySettings } from "../settings";

export const SYMPHONY_DASHBOARD_VIEW_TYPE = "symphony-dashboard";

export class SymphonyDashboardView extends ItemView {
	constructor(
		leaf: WorkspaceLeaf,
		private readonly getSettings: () => SymphonySettings,
		private readonly getIssueIndex: () => IssueIndexSnapshot | null,
		private readonly getExecutionSummaries: () => ExecutionJobSummary[],
	) {
		super(leaf);
	}

	getViewType(): string {
		return SYMPHONY_DASHBOARD_VIEW_TYPE;
	}

	getDisplayText(): string {
		return "Symphony dashboard";
	}

	async onOpen(): Promise<void> {
		this.render();
	}

	async onClose(): Promise<void> {
		this.contentEl.empty();
	}

	render(): void {
		const settings = this.getSettings();
		const issueIndex = this.getIssueIndex();
		const executionSummaries = this.getExecutionSummaries();
		const { contentEl } = this;
		contentEl.empty();
		contentEl.addClass("symphony-dashboard");

		const intro = contentEl.createDiv({ cls: "symphony-dashboard__section" });
		intro.createEl("h2", {
			text: "Symphony execution",
			cls: "symphony-dashboard__title",
		});
		intro.createEl("p", {
			text: "This dashboard indexes project-related issue notes and dispatches eligible work using the effective runtime policy from WORKFLOW.md plus local overrides.",
			cls: "symphony-dashboard__meta",
		});

		const settingsSection = contentEl.createDiv({ cls: "symphony-dashboard__section" });
		settingsSection.createEl("h3", {
			text: "Effective runtime config",
			cls: "symphony-dashboard__title",
		});

		const settingsList = settingsSection.createEl("ul", {
			cls: "symphony-dashboard__list",
		});
		const rows: Array<[string, string]> = [
			["Issue folder", settings.issueFolderPath],
			["Project-related marker", settings.projectRelatedMarker],
			["Runner command", settings.runnerCommandTemplate || "Not set"],
			["Auto-dispatch", settings.autoDispatchProjectTasks ? "Enabled" : "Disabled"],
			["Max concurrent runs", String(settings.maxConcurrentRuns)],
			["Runner timeout", settings.runnerTimeoutMs === null ? "Not set" : `${settings.runnerTimeoutMs}ms`],
			["Workflow file", settings.workflowFilePath],
			["Workspace root", settings.desktopWorkspaceRoot || "Not set"],
			["Log root", settings.desktopLogRoot || "Not set"],
			["Auto start", settings.autoStart ? "Enabled" : "Disabled"],
			["Open dashboard on start", settings.dashboardOpenOnStart ? "Enabled" : "Disabled"],
			["HTTP port override", settings.httpPortOverride === null ? "Not set" : String(settings.httpPortOverride)],
			["Allow workspace inside vault", settings.allowWorkspaceInsideVault ? "Enabled" : "Disabled"],
		];

		for (const [label, value] of rows) {
			settingsList.createEl("li", {
				text: `${label}: ${value}`,
			});
		}

		const indexedSection = contentEl.createDiv({ cls: "symphony-dashboard__section" });
		indexedSection.createEl("h3", {
			text: "Indexed issues",
			cls: "symphony-dashboard__title",
		});

		if (!issueIndex) {
			indexedSection.createEl("p", {
				text: "Issue index not loaded yet.",
				cls: "symphony-dashboard__meta",
			});
		} else {
			indexedSection.createEl("p", {
				text: `${issueIndex.projectRelatedCount} project-related issue(s), ${issueIndex.eligibleCount} eligible for work.`,
				cls: "symphony-dashboard__meta",
			});

			const indexedList = indexedSection.createEl("ul", {
				cls: "symphony-dashboard__list",
			});

			if (issueIndex.issues.length === 0) {
				indexedList.createEl("li", {
					text: `No Markdown issues found under ${issueIndex.issueFolderPath}.`,
				});
			} else {
				for (const issue of issueIndex.issues.slice(0, 12)) {
					const label = issue.eligible ? "Will work" : issue.projectRelated ? "Tracked" : "Ignored";
					indexedList.createEl("li", {
						text: `${label}: ${issue.title} [${issue.state}] runtime=${issue.runtimeStatus} - ${issue.path}`,
					});
				}
			}
		}

		const executionSection = contentEl.createDiv({ cls: "symphony-dashboard__section" });
		executionSection.createEl("h3", {
			text: "Execution jobs",
			cls: "symphony-dashboard__title",
		});
		const executionList = executionSection.createEl("ul", {
			cls: "symphony-dashboard__list",
		});

		if (executionSummaries.length === 0) {
			executionList.createEl("li", {
				text: "No jobs have been started yet.",
			});
		} else {
			for (const summary of executionSummaries) {
				executionList.createEl("li", {
					text: `${summary.state.toUpperCase()}: ${summary.title} - ${summary.outcome} (${summary.subtitle})`,
				});
			}
		}
	}
}
