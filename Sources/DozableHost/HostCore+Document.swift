import DozableChat
import Foundation

// 755: `workspace-doc` — a workspace's document, for EVERY workspace (`RecordDocument`; docs/engineering/workspace-model.md).
// Read-only: answered in-process when no daemon runs; never opens a file but the store's own (the record, its brief.md and
// the spec its last up recorded, `space.json`) and the logs (which rooms each workspace made). Never YAML.

extension HostCore {
    func workspaceDocument(_ w: WorkspaceRequest) throws -> WorkspaceDocumentAnswer {
        let n = try workspaceName(w)
        let rec = try workspaceRecord(n)
        let host = RecordDocument.hostSlug(Self.spaceStateHost())
        var notes: [String] = []
        if SpaceRecordRef.of(rec) != nil {
            let folder = WorkspaceStore.resolved(workspaces.folder(n))
            if let data = try? MacFenceHostFS.readRegular(folder + "/space.json", maximum: SpaceRequest.maximumBytes),
               let spec = try? ChatJSON.parse(data), case .object = spec {
                let g = RecordDocument.merge(spec: spec, record: rec, host: host)
                return WorkspaceDocumentAnswer(workspace: n, from: "space-file", document: SpaceDoc.text(RecordDocument.view(g.document)), notes: g.notes)
            }
            notes.append("its space was recorded by an older doz: the document is generated from its record (doz workspace up -f FILE records it again)")
        }
        let log = (try? workspaces.log(n)) ?? []
        let made = Set(log.filter { $0.action == "room-made" }.compactMap(\.room))
        // The shared-room rule: a room this workspace linked is owned by the workspace whose log says it made it.
        var owners: [String: String] = [:]
        let linked = rec.rooms.filter { $0.goneAt == nil && !($0.owned ?? made.contains($0.chatRoom)) }.map(\.chatRoom)
        if !linked.isEmpty {
            for other in workspaces.names() where other != n {
                for e in (try? workspaces.log(other)) ?? [] where e.action == "room-made" {
                    if let r = e.room, linked.contains(r), owners[r] == nil { owners[r] = other }
                }
            }
        }
        let inputs = RecordDocument.Inputs(record: rec, briefText: workspaceBriefText(rec) ?? "", owner: (try? ChatDirectory.load(chatPaths))?.human,
                                           host: host, roomsMade: made, roomOwners: owners)
        let g = RecordDocument.generate(inputs)
        return WorkspaceDocumentAnswer(workspace: n, from: "record", document: SpaceDoc.text(RecordDocument.view(g.document)), notes: notes + g.notes)
    }
}
