import { readdir, readFile } from 'node:fs/promises'
import { homedir, platform } from 'node:os'
import { isAbsolute, join, normalize, resolve, sep } from 'node:path'

import type { PluginAPI } from '@ampcode/plugin'

interface NeovimLockfile {
	port: number
	authToken: string
	pid: number
	workspaceFolders: string[]
	ideName: string
}

interface ProtocolDiagnostic {
	range: {
		startLine: number
		startCharacter: number
		endLine: number
		endCharacter: number
	}
	severity: string
	description: string
	lineContent: string
	startOffset: number
	endOffset: number
}

interface DiagnosticsEntry {
	uri: string
	diagnostics: ProtocolDiagnostic[]
}

interface AmpDiagnostic {
	uri: string
	message: string
	severity: 'error' | 'warning' | 'info' | 'hint'
	source: string | undefined
	range: {
		type: 'full'
		start: { line: number; character: number }
		end: { line: number; character: number }
	}
}

interface GetDiagnosticsResponse {
	serverResponse?: {
		id: string
		error?: { message?: string }
		getDiagnostics?: { entries: DiagnosticsEntry[] }
	}
}

const requestTimeoutMilliseconds = 2_000

function dataHome(): string {
	const override = process.env.AMP_DATA_HOME
	if (override) {
		return override
	}

	if (platform() === 'linux' && process.env.XDG_DATA_HOME) {
		return process.env.XDG_DATA_HOME
	}

	return join(homedir(), '.local', 'share')
}

function ideLockfileDir(): string {
	return join(dataHome(), 'amp', 'ide')
}

function isProcessAlive(pid: number): boolean {
	try {
		process.kill(pid, 0)
		return true
	} catch (error) {
		return error instanceof Error && 'code' in error && error.code === 'EPERM'
	}
}

function isNeovimLockfile(value: unknown): value is NeovimLockfile {
	if (!value || typeof value !== 'object') {
		return false
	}

	const lockfile = value as Partial<NeovimLockfile>
	return (
		typeof lockfile.port === 'number' &&
		typeof lockfile.authToken === 'string' &&
		typeof lockfile.pid === 'number' &&
		Array.isArray(lockfile.workspaceFolders) &&
		lockfile.workspaceFolders.every((folder) => typeof folder === 'string') &&
		typeof lockfile.ideName === 'string' &&
		lockfile.ideName.toLowerCase().includes('nvim')
	)
}

function pathWithTrailingSeparator(path: string): string {
	return path.endsWith(sep) ? path : `${path}${sep}`
}

function hasHierarchicalMatch(workspaceFolders: string[], requestedPath: string): boolean {
	const normalizedPath = pathWithTrailingSeparator(normalize(resolve(requestedPath)))
	return workspaceFolders.some((folder) => {
		const normalizedFolder = pathWithTrailingSeparator(normalize(resolve(folder)))
		return (
			normalizedPath.startsWith(normalizedFolder) || normalizedFolder.startsWith(normalizedPath)
		)
	})
}

async function readLockfiles(): Promise<NeovimLockfile[]> {
	let entries: string[]
	try {
		entries = await readdir(ideLockfileDir())
	} catch (error) {
		if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
			return []
		}
		throw error
	}

	const lockfiles = await Promise.all(
		entries
			.filter((entry) => entry.endsWith('.json'))
			.map(async (entry) => {
				try {
					const raw = await readFile(join(ideLockfileDir(), entry), 'utf8')
					const parsed = JSON.parse(raw)
					return isNeovimLockfile(parsed) && isProcessAlive(parsed.pid) ? parsed : null
				} catch {
					return null
				}
			}),
	)

	return lockfiles.filter((lockfile) => lockfile !== null)
}

async function selectLockfile(path: string): Promise<NeovimLockfile | undefined> {
	const lockfiles = await readLockfiles()
	return lockfiles
		.filter((lockfile) => hasHierarchicalMatch(lockfile.workspaceFolders, path))
		.sort((a, b) => {
			const aLength = a.workspaceFolders[0]?.length ?? 0
			const bLength = b.workspaceFolders[0]?.length ?? 0
			return bLength - aLength || a.ideName.localeCompare(b.ideName)
		})[0]
}

function requestDiagnostics(lockfile: NeovimLockfile, path: string): Promise<DiagnosticsEntry[]> {
	return new Promise((resolve, reject) => {
		const requestID = crypto.randomUUID()
		const websocket = new WebSocket(
			`ws://127.0.0.1:${lockfile.port}?auth=${encodeURIComponent(lockfile.authToken)}`,
		)
		const timeout = setTimeout(() => {
			websocket.close()
			reject(
				new Error(`Timed out waiting for Neovim diagnostics after ${requestTimeoutMilliseconds}ms`),
			)
		}, requestTimeoutMilliseconds)

		websocket.addEventListener('open', () => {
			websocket.send(
				JSON.stringify({
					clientRequest: {
						id: requestID,
						getDiagnostics: { path },
					},
				}),
			)
		})

		websocket.addEventListener('message', (message) => {
			const parsed = JSON.parse(String(message.data)) as GetDiagnosticsResponse
			const response = parsed.serverResponse
			if (response?.id !== requestID) {
				return
			}

			clearTimeout(timeout)
			websocket.close()
			if (response.error) {
				reject(new Error(response.error.message ?? 'Neovim diagnostics request failed'))
				return
			}
			resolve(response.getDiagnostics?.entries ?? [])
		})

		websocket.addEventListener('error', () => {
			clearTimeout(timeout)
			reject(new Error('Failed to connect to the Amp Neovim plugin'))
		})
	})
}

function severity(value: string): 'error' | 'warning' | 'info' | 'hint' {
	switch (value.toLowerCase()) {
		case 'error':
			return 'error'
		case 'warning':
		case 'warn':
			return 'warning'
		case 'hint':
			return 'hint'
		default:
			return 'info'
	}
}

function convertDiagnostics(entries: DiagnosticsEntry[]): AmpDiagnostic[] {
	const diagnostics = entries.flatMap((entry) =>
		entry.diagnostics.map((diagnostic) => ({
			uri: entry.uri,
			message: diagnostic.description,
			severity: severity(diagnostic.severity),
			source: undefined,
			range: {
				type: 'full' as const,
				start: {
					line: diagnostic.range.startLine + 1,
					character: diagnostic.range.startCharacter,
				},
				end: {
					line: diagnostic.range.endLine + 1,
					character: diagnostic.range.endCharacter,
				},
			},
		})),
	)

	diagnostics.sort((a, b) => {
		const severityOrder = { error: 0, warning: 1, info: 2, hint: 3 }
		return severityOrder[a.severity] - severityOrder[b.severity] || a.uri.localeCompare(b.uri)
	})

	return diagnostics
}

export default function (amp: PluginAPI) {
	amp.registerTool({
		name: 'get_diagnostics',
		description:
			'Get LSP diagnostics from the connected Amp Neovim plugin for an absolute file or directory path. Use this when the user asks about errors, warnings, type errors, or diagnostics from Neovim.',
		inputSchema: {
			type: 'object',
			properties: {
				path: {
					type: 'string',
					description: 'Absolute path to a file or directory to get diagnostics for.',
				},
			},
			required: ['path'],
		},
		async execute(input) {
			const path = typeof input.path === 'string' ? input.path : ''
			if (!path || !isAbsolute(path)) {
				throw new Error('path must be an absolute path')
			}

			const lockfile = await selectLockfile(path)
			if (!lockfile) {
				return `No running Amp Neovim plugin was found for ${path}. Start Neovim with require('amp').setup({ auto_start = true }).`
			}

			return convertDiagnostics(await requestDiagnostics(lockfile, path))
		},
	})
}
