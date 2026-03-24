import { mkdir, readFile, writeFile, copyFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { createHash } from "node:crypto";

const pluginRoot = resolve(import.meta.dirname, "..");
const VAULTS_ROOT = "C:\\dev\\Desktop-Projects\\Helpful-Docs-Prompts\\VAULTS-OBSIDIAN";

const KNOWN_INSTANCE_IDS = new Map([
	["C:\\dev\\Desktop-Projects\\Helpful-Docs-Prompts\\VAULTS-OBSIDIAN\\SPWR", "154dd54fbb28677a"],
	["C:\\dev\\Desktop-Projects\\Helpful-Docs-Prompts\\VAULTS-OBSIDIAN\\designandbuilding-vault", "ff6a20e5b5ab012f"],
	["C:\\dev\\Desktop-Projects\\Helpful-Docs-Prompts\\VAULTS-OBSIDIAN\\Obsidian Vault", "d9ad5d53b8c04e47"],
	["C:\\dev\\Desktop-Projects\\Helpful-Docs-Prompts\\VAULTS-OBSIDIAN\\Solana-Grow", "5b38e127d20be493"],
]);

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
	const targets = await discoverVaultTargets();
	for (const target of targets) {
		await installToVault(target);
	}
}

async function discoverVaultTargets() {
	const entries = await readdir(VAULTS_ROOT, { withFileTypes: true });
	const targets = [];

	for (const entry of entries) {
		if (!entry.isDirectory()) {
			continue;
		}

		const candidateRoot = join(VAULTS_ROOT, entry.name);
		const vaultRoot = await resolveVaultRoot(candidateRoot);
		if (!vaultRoot) {
			continue;
		}

		targets.push({
			root: vaultRoot,
			instanceId: await resolveInstanceId(vaultRoot),
		});
	}

	return targets;
}

async function resolveVaultRoot(candidateRoot) {
	if (existsSync(join(candidateRoot, ".obsidian"))) {
		return candidateRoot;
	}

	const entries = await readdir(candidateRoot, { withFileTypes: true });
	for (const entry of entries) {
		if (!entry.isDirectory()) {
			continue;
		}

		const nestedRoot = join(candidateRoot, entry.name);
		if (existsSync(join(nestedRoot, ".obsidian"))) {
			return nestedRoot;
		}
	}

	return null;
}

async function resolveInstanceId(vaultRoot) {
	const existingDataPath = join(vaultRoot, ".obsidian", "plugins", "symphony", "data.json");
	const existingData = await readJsonFile(existingDataPath);
	const existingInstanceId = existingData?.settings?.symphonyInstanceId;
	if (typeof existingInstanceId === "string" && existingInstanceId.trim()) {
		return existingInstanceId.trim();
	}

	const knownInstanceId = KNOWN_INSTANCE_IDS.get(vaultRoot);
	if (knownInstanceId) {
		return knownInstanceId;
	}

	return createHash("sha256").update(vaultRoot.toLowerCase()).digest("hex").slice(0, 16);
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
