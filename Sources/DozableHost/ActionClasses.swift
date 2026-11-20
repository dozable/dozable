import Foundation

/// What an agent's request needs, by its HostOp — pure. EVERY operation is classified (the switch has no default, so a new
/// HostOp does not compile until it is): either the permissions it needs and the workspace it acts in, or Dozable's own —
/// never for an agent (an account, a key, a token, a terminal, the daemon, the settings, the ceilings themselves, anything
/// not in the table). Several needs: the strictest answer wins (a worker added unfenced needs `worker.start` and
/// `isolation.unfenced`). Only an agent's request is ever classified: the owner is never gated (`PermissionGate`).
/// docs/engineering/workspaces.md, "Permissions".
public enum ActionClass: Equatable, Sendable {
    /// Dozable's own: never for an agent, whatever it is granted.
    case dozableOwn
    /// These permissions (never empty), in this place.
    case needs([String], ActionTarget)
}

/// Where an action is: a workspace by name, a place (a sandbox or a session on this Mac) by its membership key, a chat room,
/// or nowhere in particular (outside every workspace).
public enum ActionTarget: Equatable, Sendable {
    case workspace(String?)
    case place(String?)
    case room(String?)
    case nowhere
}

public enum ActionClasses {
    /// The place a request names: `sandbox:NAME`, or `mac:SESSION` for `@mac`.
    static func place(_ r: HostRequest) -> ActionTarget {
        guard let n = r.name else { return .place(nil) }
        if MacPlace.isPlace(n) { return .place(r.session.map { "mac:" + $0 }) }
        return .place("sandbox:" + n)
    }

    /// The folder permissions a list of folders needs, by mode.
    static func folders(_ fs: [WorkspaceFolder]) -> [String] {
        var out: [String] = []
        if fs.contains(where: { $0.mode == "ro" }) { out.append("folder.read") }
        if fs.contains(where: { $0.mode != "ro" }) { out.append("folder.write") }
        return out
    }

    static func needs(_ perms: [String], _ t: ActionTarget) -> ActionClass {
        var seen: [String] = []
        for p in perms where !seen.contains(p) { seen.append(p) }
        return seen.isEmpty ? .dozableOwn : .needs(seen, t)
    }

    public static func classify(_ r: HostRequest) -> ActionClass {
        let w = r.workspaceRequest
        let ws = ActionTarget.workspace(w?.name)
        switch r.op {
        // workspace.read — its workspace, and the screens of its own agents
        case .workspaceShow, .workspaceLog, .workspaceReach, .workspaceFolders, .workspaceRuns, .workspaceRunChat:
            return needs(["workspace.read"], ws)
        case .workerList:
            return needs(["workspace.read"], .workspace(r.workerRequest?.workspace))
        case .permissionsShow, .permissionsWhy:
            return needs(["workspace.read"], .workspace(r.permissionsRequest?.workspace ?? r.permissionsRequest?.room?.split(separator: "/").first.map(String.init)))
        case .sessionScreen:
            return needs(["workspace.read"], place(r))
        // agent.start / agent.stop
        case .workspaceStart:
            return needs(["agent.start"], ws)
        case .workspaceStop:
            return needs(["agent.stop"], ws)
        case .start, .wake, .resume, .sessionResume, .sessionRestart:
            return needs(["agent.start"], place(r))
        case .pause, .sleep, .hibernate, .shutdown, .sessionEnd:
            return needs(["agent.stop"], place(r))
        case .openSession:
            var p = ["agent.start"]
            if MacPlace.isPlace(r.name) {
                if let f = r.macFence {
                    if !(f.read ?? []).isEmpty { p.append("folder.read") }
                    if !(f.write ?? []).isEmpty { p.append("folder.write") }
                } else {
                    p.append("isolation.unfenced")
                }
            }
            if !(r.secrets ?? []).isEmpty { p.append("secret.use") }
            return needs(p, place(r))
        // workers
        case .workerAdd:
            var p = ["worker.start"]
            if r.workerRequest?.isolation == "unfenced" { p.append("isolation.unfenced") }
            if !(r.secrets ?? []).isEmpty { p.append("secret.use") }
            return needs(p, .workspace(r.workerRequest?.workspace))
        case .workerEnd:
            return needs(["worker.stop"], .workspace(r.workerRequest?.workspace))
        // a workspace made or edited: its room, its folders, an unfenced manager
        case .workspaceNew:
            var p = ["room.manage"]
            if w?.managerIsolation == "unfenced" { p.append("isolation.unfenced") }
            p += folders(w?.folders ?? [])
            return needs(p, ws)
        case .workspaceEdit:
            var p: [String] = []
            if w?.managerIsolation == "unfenced" { p.append("isolation.unfenced") }
            p += folders((w?.folders ?? []) + (w?.addFolders ?? []))
            return needs(p, ws)
        // the network
        case .netPolicy, .portOpen, .ports:
            return needs(["net.allow"], place(r))
        // your Keychain
        case .accountUse:
            return needs(["keychain.use"], place(r))
        case .accessGithubKey:
            return needs(["keychain.use"], .nowhere)
        // folders and files
        case .filesMkdir, .filesNew, .filesMove:
            return needs(["folder.write"], place(r))
        case .filesRm, .pointRm, .rm:
            return needs(["delete"], place(r))
        case .imageRm:
            return needs(["delete"], .nowhere)
        // rooms
        case .chatRoomArchive, .chatRoomRm:
            return needs(["room.manage"], .room(r.chatRoom?.room))
        case .chatAdd, .chatRemove, .chatSet:
            return needs(["room.manage"], .nowhere)
        // the lifecycle
        case .workspaceSleep, .workspaceWake:
            return needs(["workspace.sleep"], ws)
        case .workspaceFinish, .workspaceReopen:
            return needs(["workspace.finish"], ws)
        case .workspaceArchive, .workspaceRestore, .workspaceRunArchive:
            return needs(["workspace.archive"], ws)
        case .workspaceDelete:
            return needs(["workspace.delete"], ws)
        // Agents / Bots
        case .botNew, .botSet, .botRetire, .botAdopt:
            return needs(["bot.manage"], .nowhere)
        // passing grants on
        case .permissionsGrant, .permissionsRevoke:
            let p = r.permissionsRequest
            return needs(["grant.give"], .workspace(p?.workspace ?? p?.room?.split(separator: "/").first.map(String.init)))
        // Dozable's own: never for an agent.
        case .ping, .create, .reset, .ls, .inspect, .sessions, .attach, .exec,
             .pointTake, .pointList, .pointRevert, .pointFork, .pointSaveImage, .imageList, .imageBake,
             .netLog, .netPermissions, .keySet, .keyRm, .keyList, .keyPolicy,
             .accountList, .accountAdd, .accountRemove, .accountDefault, .accountVerify, .accountRefresh, .accountEdit, .accountKeepalive,
             .events, .hostStop, .console, .imageTree, .templateCreate, .duplicate, .prepare, .prepareStatus, .prepareCancel, .onboard,
             .agentPrompt, .terminalLayout, .terminalLayoutSet, .bootLog, .buildLog, .resources, .resourcesRemove, .resourcesClean,
             .resourcesKernel, .bases, .builderStatus, .builderStart, .builderInstall, .sandboxSettings, .access, .tools, .toolsApply,
             .workspaceRules, .sessionForget, .sessionSend, .sessionLive, .sessionWait, .sessionQuarantine, .sessionBridges,
             .sessionTranscripts, .plan, .copy, .plans, .models, .filesList, .filesOpen, .editors, .filesTree, .filesTreeSet, .rename,
             .sessionGrids, .dotfiles, .dotfilesResolve, .dotfilesUpdate,
             .chatSync, .chatToken, .chatMembers, .chatWebhookSet, .chatWebhookRemove, .chatWebhookStatus, .chatImport,
             .workspaceList, .workspaceAdopt, .workspaceRelease, .workspaceRename, .workspacePlan, .workspaceLifecyclePlan,
             .chatRoomPlan, .botList, .botShow, .botToken, .workerPlan, .workspaceUpPlan, .workspaceUp, .workspaceDownPlan, .workspaceDown, .chatRoomClose, .chatRoomOpen, .macsList, .permissionsCeiling,
             .workspaceState, .workspaceSpace, .workspaceSpaceSave:
            return .dozableOwn
        }
    }
}
