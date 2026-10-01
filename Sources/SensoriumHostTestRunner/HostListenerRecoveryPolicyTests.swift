import SensoriumHost

/// When the host's QUIC listener is rebuilt after the tailnet interface
/// changes under it, decided without a socket.
func runHostListenerRecoveryPolicyTests() {
    let utun4 = HostListenerInterfaceIdentity(name: "utun4", index: 21)
    let utun4Reattached = HostListenerInterfaceIdentity(name: "utun4", index: 22)
    let utun6 = HostListenerInterfaceIdentity(name: "utun6", index: 23)

    do {
        var policy = HostListenerRecoveryPolicy(boundInterface: utun4)
        expect(policy.listenerEvent(.ready, generation: 0) == .report, "the first ready is reported")
        expect(policy.interfaceObserved(utun4) == .none, "the same interface seen again changes nothing")
        expect(
            policy.interfaceObserved(utun6) == .rebuild(afterSeconds: 0),
            "the tailnet address moving to another interface rebuilds the listener at once"
        )
        expect(policy.interfaceObserved(utun6) == .none, "a rebuild already pending is not requested twice")
        print("PASS: the listener is rebuilt when the tailnet address moves to a different interface")
    }

    do {
        var policy = HostListenerRecoveryPolicy(boundInterface: utun4)
        _ = policy.listenerEvent(.ready, generation: 0)
        expect(policy.interfaceObserved(nil) == .none, "nothing can be bound while the tailnet address is gone")
        expect(
            policy.interfaceObserved(utun4) == .rebuild(afterSeconds: 0),
            "the interface coming back under the same name and index still rebuilds, since the old one went away"
        )
        let generation = policy.rebuildBegan(on: utun4)
        expect(generation == 1, "each rebuild starts a new generation")
        expect(policy.interfaceObserved(utun4) == .none, "the rebuilt listener's own interface changes nothing")
        expect(
            policy.interfaceObserved(utun4Reattached) == .rebuild(afterSeconds: 0),
            "the same name under a new index is a different interface"
        )
        print("PASS: the listener is rebuilt when the tailnet interface goes away and comes back, even under the same name")
    }

    do {
        var policy = HostListenerRecoveryPolicy(boundInterface: utun4)
        expect(
            policy.listenerEvent(.failed, generation: 0) == .report,
            "a first bind that fails is reported, so the host can say it could not start hosting"
        )
        print("PASS: a failed first bind is still reported rather than retried")
    }

    do {
        var policy = HostListenerRecoveryPolicy(boundInterface: utun4)
        _ = policy.listenerEvent(.ready, generation: 0)
        expect(
            policy.listenerEvent(.waiting, generation: 0) == .rebuild(afterSeconds: 0),
            "a listener waiting for a usable network is rebuilt"
        )
        var generation = policy.rebuildBegan(on: utun6)
        expect(
            policy.listenerEvent(.cancelled, generation: 0) == .none,
            "the replaced listener's cancellation is not reported as the host stopping"
        )
        expect(
            policy.listenerEvent(.failed, generation: 0) == .none,
            "a late event from the replaced listener is ignored"
        )
        var delays: [Double] = []
        for _ in 0..<7 {
            guard case let .rebuild(delay) = policy.listenerEvent(.failed, generation: generation) else {
                expect(false, "a rebuilt listener that fails is retried, not reported as a bind failure")
                break
            }
            delays.append(delay)
            generation = policy.rebuildBegan(on: utun6)
        }
        expect(delays == [1, 2, 4, 8, 16, 30, 30], "retries back off and cap at thirty seconds, got \(delays)")
        expect(policy.listenerEvent(.ready, generation: generation) == .report, "a rebuilt listener's ready is reported")
        _ = policy.listenerEvent(.waiting, generation: generation)
        generation = policy.rebuildBegan(on: utun6)
        expect(
            policy.listenerEvent(.failed, generation: generation) == .rebuild(afterSeconds: 1),
            "the backoff starts over once a rebuilt listener is ready"
        )
        expect(
            policy.listenerEvent(.cancelled, generation: generation) == .report,
            "the current listener's cancellation is reported"
        )
        print("PASS: a rebuilt listener that fails is retried with a capped backoff, and the replaced listener's events are ignored")
    }

    do {
        var policy = HostListenerRecoveryPolicy(boundInterface: utun4)
        _ = policy.listenerEvent(.ready, generation: 0)
        _ = policy.interfaceObserved(utun6)
        policy.rebuildFoundNoInterface()
        expect(
            policy.interfaceObserved(utun6) == .rebuild(afterSeconds: 0),
            "a rebuild that found no interface to scope to waits for the interface to appear, never binding unscoped"
        )
        print("PASS: a rebuild with no tailnet interface to scope to waits for one instead of binding unscoped")
    }

    do {
        var policy = HostListenerRecoveryPolicy(boundInterface: nil)
        _ = policy.listenerEvent(.ready, generation: 0)
        expect(
            policy.interfaceObserved(utun4) == .rebuild(afterSeconds: 0),
            "a listener started before its interface was known is rebuilt scoped to it"
        )
        print("PASS: a listener started without interface scoping is rebuilt scoped once the interface appears")
    }
}
