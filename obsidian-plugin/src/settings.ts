export interface SymphonySettings {
	workflowFilePath: string;
	issueFolderPath: string;
	projectRelatedMarker: string;
	symphonyInstanceId: string;
	runnerCommandTemplate: string;
	autoDispatchProjectTasks: boolean;
	maxConcurrentRuns: number;
	runnerTimeoutMs: number | null;
	desktopWorkspaceRoot: string;
	desktopLogRoot: string;
	autoStart: boolean;
	dashboardOpenOnStart: boolean;
	httpPortOverride: number | null;
	allowWorkspaceInsideVault: boolean;
}

export const DEFAULT_SETTINGS: SymphonySettings = {
	workflowFilePath: "symphony/WORKFLOW.md",
	issueFolderPath: "symphony/issues",
	projectRelatedMarker: "project-related",
	symphonyInstanceId: "",
	runnerCommandTemplate: "",
	autoDispatchProjectTasks: false,
	maxConcurrentRuns: 1,
	runnerTimeoutMs: null,
	desktopWorkspaceRoot: "",
	desktopLogRoot: "",
	autoStart: false,
	dashboardOpenOnStart: false,
	httpPortOverride: null,
	allowWorkspaceInsideVault: false,
};
