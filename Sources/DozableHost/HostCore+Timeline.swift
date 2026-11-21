import Foundation

// 747: the daemon's side of the timeline — the indexer started, poked by every write, caught up at start, every 30
// seconds for the chat server's rooms and a space's frames, and hourly for everything.

extension HostCore {
    /// The daemon only: register the store's pokes and keep `timeline.sqlite` caught up. Never on the actor's time: the
    /// indexer has its own queue.
    public nonisolated func startTimeline() async {
        guard let ix = timeline else { return }
        TimelineSignal.register(store.root.path) { [weak ix] p in ix?.poke(p) }
        ix.poke(.all)
        Task.detached { [weak ix] in
            var round = 0
            while !Task.isCancelled, let ix {
                try? await Task.sleep(for: .seconds(30))
                round += 1
                ix.poke(.chat)
                ix.poke(.runs)
                if round % 120 == 0 { ix.poke(.all) }
            }
        }
    }

    /// Something the timeline keeps changed (a sample, a record written elsewhere).
    nonisolated func timelinePoke(_ p: TimelinePoke) { timeline?.poke(p) }
}
