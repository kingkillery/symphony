import { spawn, type ChildProcessWithoutNullStreams } from "child_process";

export type ExecutionJobState = "queued" | "running" | "completed" | "failed" | "cancelled";

export interface ExecutionPathContext {
	issuePath: string;
	issueTitle: string;
	vaultPath: string;
	workspaceRoot: string;
	logRoot: string;
}

export interface ExecutionCommandTemplate {
	command: string;
	args?: string[];
	cwd?: string;
	shell?: boolean;
	env?: Record<string, string>;
}

export interface ExecutionJobRequest {
	id: string;
	createdAt: number;
	context: ExecutionPathContext;
	template: ExecutionCommandTemplate;
}

export interface ExecutionJobQueued extends ExecutionJobRequest {
	state: "queued";
}

export interface ExecutionJobRunning extends ExecutionJobRequest {
	state: "running";
	pid: number;
	startedAt: number;
}

export interface ExecutionJobCompleted extends ExecutionJobRunning {
	state: "completed";
	endedAt: number;
	exitCode: number | null;
	signal: string | null;
	stdout: string;
	stderr: string;
}

export interface ExecutionJobFailed extends ExecutionJobRequest {
	state: "failed";
	startedAt: number | null;
	endedAt: number;
	pid: number | null;
	exitCode: number | null;
	signal: string | null;
	error: string;
	stdout: string;
	stderr: string;
}

export interface ExecutionJobCancelled extends ExecutionJobRequest {
	state: "cancelled";
	startedAt: number | null;
	endedAt: number;
	pid: number | null;
	reason: string;
	stdout: string;
	stderr: string;
}

export type ExecutionJob =
	| ExecutionJobQueued
	| ExecutionJobRunning
	| ExecutionJobCompleted
	| ExecutionJobFailed
	| ExecutionJobCancelled;

export interface ExecutionJobSummary {
	id: string;
	state: ExecutionJobState;
	title: string;
	subtitle: string;
	outcome: string;
	hasError: boolean;
	canRetry: boolean;
}

export interface ExecutionDispatchOptions {
	environment?: Record<string, string>;
	workingDirectory?: string;
	timeoutMs?: number;
	jobId?: string;
}

export interface ExecutionStartResult {
	runningJob: ExecutionJobRunning;
	completed: Promise<ExecutionJob>;
	cancel: (reason?: string) => Promise<ExecutionJobCancelled>;
}

export interface ExecutionProcessRunner {
	start(request: ExecutionJobRequest, options?: ExecutionDispatchOptions): Promise<ExecutionStartResult>;
}

export function applyExecutionTemplate(value: string, context: ExecutionPathContext): string {
	return value.replace(/\{\{([a-zA-Z0-9_]+)\}\}/g, (_match, token: string) => {
		switch (token) {
			case "issue_path":
				return context.issuePath;
			case "issue_title":
				return context.issueTitle;
			case "vault_path":
				return context.vaultPath;
			case "workspace_root":
				return context.workspaceRoot;
			case "log_root":
				return context.logRoot;
			default:
				return _match;
		}
	});
}

export function resolveExecutionCommand(
	template: ExecutionCommandTemplate,
	context: ExecutionPathContext,
): Required<Pick<ExecutionCommandTemplate, "command">> & {
	args: string[];
	cwd: string | undefined;
	shell: boolean;
	env: Record<string, string>;
} {
	return {
		command: applyExecutionTemplate(template.command, context),
		args: (template.args ?? []).map((arg) => applyExecutionTemplate(arg, context)),
		cwd: template.cwd ? applyExecutionTemplate(template.cwd, context) : undefined,
		shell: template.shell ?? false,
		env: resolveTemplateEnv(template.env ?? {}, context),
	};
}

export function summarizeExecutionJob(job: ExecutionJob): ExecutionJobSummary {
	switch (job.state) {
		case "queued":
			return {
				id: job.id,
				state: job.state,
				title: job.context.issueTitle,
				subtitle: job.context.issuePath,
				outcome: "Waiting to start",
				hasError: false,
				canRetry: false,
			};
		case "running":
			return {
				id: job.id,
				state: job.state,
				title: job.context.issueTitle,
				subtitle: `pid ${job.pid}`,
				outcome: "Running",
				hasError: false,
				canRetry: false,
			};
		case "completed":
			return {
				id: job.id,
				state: job.state,
				title: job.context.issueTitle,
				subtitle: job.context.issuePath,
				outcome: job.exitCode === 0 ? "Completed successfully" : `Exited with code ${job.exitCode ?? "unknown"}`,
				hasError: job.exitCode !== 0,
				canRetry: job.exitCode !== 0,
			};
		case "cancelled":
			return {
				id: job.id,
				state: job.state,
				title: job.context.issueTitle,
				subtitle: job.context.issuePath,
				outcome: `Cancelled: ${job.reason}`,
				hasError: true,
				canRetry: true,
			};
		case "failed":
			return {
				id: job.id,
				state: job.state,
				title: job.context.issueTitle,
				subtitle: job.context.issuePath,
				outcome: job.error,
				hasError: true,
				canRetry: true,
			};
	}
}

export class NodeExecutionProcessRunner implements ExecutionProcessRunner {
	async start(
		request: ExecutionJobRequest,
		options: ExecutionDispatchOptions = {},
	): Promise<ExecutionStartResult> {
		let resolvedTemplate: ReturnType<typeof resolveExecutionCommand>;
		try {
			resolvedTemplate = resolveExecutionCommand(request.template, request.context);
		} catch (error) {
			const failedJob = this.toFailedJob(request, null, null, `Failed to resolve template: ${toErrorMessage(error)}`);
			return {
				runningJob: {
					...request,
					state: "running",
					pid: -1,
					startedAt: request.createdAt,
				},
				completed: Promise.resolve(failedJob),
				cancel: async (reason = "Cancelled by operator") => ({
					...request,
					state: "cancelled",
					startedAt: null,
					endedAt: Date.now(),
					pid: null,
					reason,
					stdout: "",
					stderr: "",
				}),
			};
		}

		let child: ChildProcessWithoutNullStreams;
		try {
			child = spawn(resolvedTemplate.command, resolvedTemplate.args, {
				cwd: options.workingDirectory ?? resolvedTemplate.cwd,
				shell: resolvedTemplate.shell,
				env: {
					...process.env,
					...resolvedTemplate.env,
					...(options.environment ?? {}),
				},
				windowsHide: true,
			});
		} catch (error) {
			const failedJob = this.toFailedJob(request, null, null, toErrorMessage(error));
			return {
				runningJob: {
					...request,
					state: "running",
					pid: -1,
					startedAt: request.createdAt,
				},
				completed: Promise.resolve(failedJob),
				cancel: async (reason = "Cancelled by operator") => ({
					...request,
					state: "cancelled",
					startedAt: null,
					endedAt: Date.now(),
					pid: null,
					reason,
					stdout: "",
					stderr: "",
				}),
			};
		}

		const startedAt = Date.now();
		const runningJob: ExecutionJobRunning = {
			...request,
			state: "running",
			pid: child.pid ?? -1,
			startedAt,
		};

		let stdout = "";
		let stderr = "";
		let finalizedJob: ExecutionJob | null = null;
		let timeoutHandle: ReturnType<typeof setTimeout> | null = null;
		let resolveCompleted: ((job: ExecutionJob) => void) | null = null;

		const completed = new Promise<ExecutionJob>((resolve) => {
			resolveCompleted = resolve;
			const finalize = (job: ExecutionJob) => {
				if (finalizedJob) {
					return;
				}
				finalizedJob = job;
				if (timeoutHandle !== null) {
					clearTimeout(timeoutHandle);
				}
				resolve(job);
			};

			child.stdout.on("data", (chunk: Buffer) => {
				stdout += chunk.toString("utf8");
			});

			child.stderr.on("data", (chunk: Buffer) => {
				stderr += chunk.toString("utf8");
			});

			child.on("error", (error) => {
				finalize({
					...request,
					state: "failed",
					startedAt,
					endedAt: Date.now(),
					pid: child.pid ?? null,
					exitCode: null,
					signal: null,
					error: toErrorMessage(error),
					stdout,
					stderr,
				});
			});

			const timeoutMs = options.timeoutMs;
			if (typeof timeoutMs === "number" && timeoutMs > 0) {
				timeoutHandle = setTimeout(() => {
					if (finalizedJob) {
						return;
					}
					child.kill();
					finalize({
						...request,
						state: "failed",
						startedAt,
						endedAt: Date.now(),
						pid: child.pid ?? null,
						exitCode: null,
						signal: null,
						error: `Timed out after ${timeoutMs}ms`,
						stdout,
						stderr,
					});
				}, timeoutMs);
			}

			child.on("close", (exitCode, signal) => {
				if (exitCode === 0) {
					finalize({
						...runningJob,
						state: "completed",
						endedAt: Date.now(),
						exitCode,
						signal,
						stdout,
						stderr,
					});
					return;
				}

				finalize({
					...request,
					state: "failed",
					startedAt,
					endedAt: Date.now(),
					pid: child.pid ?? null,
					exitCode,
					signal,
					error: signal ? `Process exited via signal ${signal}` : `Process exited with code ${exitCode}`,
					stdout,
					stderr,
				});
			});
		});

		return {
			runningJob,
			completed,
			cancel: async (reason = "Cancelled by operator") => {
				if (!finalizedJob) {
					child.kill();
				}

				const cancelledJob: ExecutionJobCancelled = {
					...request,
					state: "cancelled",
					startedAt,
					endedAt: Date.now(),
					pid: child.pid ?? null,
					reason,
					stdout,
					stderr,
				};
				finalizedJob = cancelledJob;
				if (timeoutHandle !== null) {
					clearTimeout(timeoutHandle);
				}
				resolveCompleted?.(cancelledJob);
				return cancelledJob;
			},
		};
	}

	private toFailedJob(
		request: ExecutionJobRequest,
		startedAt: number | null,
		pid: number | null,
		error: string,
		stdout = "",
		stderr = "",
		exitCode: number | null = null,
		signal: string | null = null,
	): ExecutionJobFailed {
		return {
			...request,
			state: "failed",
			startedAt,
			endedAt: Date.now(),
			pid,
			exitCode,
			signal,
			error,
			stdout,
			stderr,
		};
	}
}

function resolveTemplateEnv(env: Record<string, string>, context: ExecutionPathContext): Record<string, string> {
	const resolved: Record<string, string> = {};
	for (const [key, value] of Object.entries(env)) {
		resolved[key] = applyExecutionTemplate(value, context);
	}
	return resolved;
}

function toErrorMessage(error: unknown): string {
	if (error instanceof Error && error.message.trim()) {
		return error.message;
	}
	if (typeof error === "string" && error.trim()) {
		return error;
	}
	return "Unknown execution error";
}
