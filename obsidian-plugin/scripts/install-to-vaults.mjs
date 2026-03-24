import { mkdir, readFile, writeFile, copyFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const pluginRoot = resolve(import.meta.dirname, "..");

const TARGET_VAULTS = [
	{
		root: "C:\\dev\\Desktop-Projects\\Helpful-Docs-Prompts\\VAULTS-OBSIDIAN\\Notesandclippings\\Notesandclippings",
		instanceId: "ee6b817756f5639c",
	},
	{
		root: "C:\\dev\\Desktop-Projects\\Helpful-Docs-Prompts\\VAULTS-OBSIDIAN\\SPWR\\SPWR",
		instanceId: "154dd54fbb28677a",
	},
	{
		root: "C:\\dev\\Desktop-Projects\\Helpful-Docs-Prompts\\VAULTS-OBSIDIAN\\designandbuilding-vault\\designandbuilding-vault",
		instanceId: "ff6a20e5b5ab012f",
	},
];

const DEFAULT_SETTINGS = {
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

const DEFAULT_RUNTIME = {
	recentExecutions: [],
	retryQueue: [],
	activeIssues: [],
};

async function main() {
	for (const target of TARGET_VAULTS) {
		await installToVault(target);
	}
}

async function installToVault(target) {
	const obsidianDir = join(target.root, ".obsidian");
	const pluginDir = join(obsidianDir, "plugins", "symphony");
	await mkdir(pluginDir, { recursive: true });

	await Promise.all([
		copyFile(join(pluginRoot, "manifest.json"), join(pluginDir, "manifest.json")),
		copyFile(join(pluginRoot, "main.js"), join(pluginDir, "main.js")),
		copyFile(join(pluginRoot, "styles.css"), join(pluginDir, "styles.css")),
	]);

	await writePluginData(join(pluginDir, "data.json"), target.instanceId);
	await updateCommunityPlugins(join(obsidianDir, "community-plugins.json"));

	console.log(`Installed Symphony into ${pluginDir}`);
}

async function writePluginData(dataPath, instanceId) {
	const existing = await readJsonFile(dataPath);
	const existingWrapped = isWrappedPluginData(existing) ? existing : null;
	const existingSettings = existingWrapped?.settings ?? {};
	const existingRuntime = existingWrapped?.runtime ?? DEFAULT_RUNTIME;

	const payload = {
		settings: {
			...DEFAULT_SETTINGS,
			...existingSettings,
			symphonyInstanceId: instanceId,
		},
		runtime: {
			...DEFAULT_RUNTIME,
			...existingRuntime,
		},
	};

	await mkdir(dirname(dataPath), { recursive: true });
	await writeJsonFile(dataPath, payload);
}

async function updateCommunityPlugins(communityPluginsPath) {
	const existing = await readJsonFile(communityPluginsPath);
	const plugins = Array.isArray(existing) ? existing.filter((value) => typeof value === "string") : [];
	if (!plugins.includes("symphony")) {
		plugins.push("symphony");
	}
	await writeJsonFile(communityPluginsPath, plugins);
}

async function readJsonFile(filePath) {
	if (!existsSync(filePath)) {
		return null;
	}

	try {
		const raw = await readFile(filePath, "utf8");
		return JSON.parse(raw);
	} catch {
		return null;
	}
}

async function writeJsonFile(filePath, value) {
	await writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function isWrappedPluginData(value) {
	return typeof value === "object" && value !== null && "settings" in value && "runtime" in value;
}

main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
