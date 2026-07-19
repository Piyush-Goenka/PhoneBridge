import Foundation

public enum CallAction: String {
    case answer
    case reject
    case silence
    case end
    case none
}

public final class CallActionRegistry {
    private let lock = NSLock()
    private var pending: [String: (generation: UInt64, completion: (CallAction) -> Void)] = [:]
    // A call now outlives one 45 s poll, so the phone re-waits repeatedly and
    // a click can land in the gap between two waits. Hold that action until
    // the next wait arrives instead of dropping it on the floor.
    private var buffered: [String: CallAction] = [:]
    private var nextGeneration: UInt64 = 0
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 45) {
        self.timeout = timeout
    }

    public func register(key: String, completion: @escaping (CallAction) -> Void) {
        lock.lock()
        if let waiting = buffered.removeValue(forKey: key) {
            let previous = pending.removeValue(forKey: key)?.completion
            lock.unlock()
            previous?(.none)
            completion(waiting)
            return
        }
        nextGeneration += 1
        let generation = nextGeneration
        let previous = pending[key]?.completion
        pending[key] = (generation, completion)
        lock.unlock()
        previous?(.none)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.expire(key: key, generation: generation)
        }
    }

    public func fulfill(key: String, action: CallAction) {
        lock.lock()
        if let completion = pending.removeValue(forKey: key)?.completion {
            lock.unlock()
            completion(action)
            return
        }
        // A timeout is not a user intent, so it is never replayed later.
        if action != .none { buffered[key] = action }
        lock.unlock()
    }

    // The call is over: drop any pending wait and any unclaimed action so a
    // stale click cannot reach the phone after the fact.
    public func cancel(key: String) {
        lock.lock()
        let completion = pending.removeValue(forKey: key)?.completion
        buffered.removeValue(forKey: key)
        lock.unlock()
        completion?(.none)
    }

    private func expire(key: String, generation: UInt64) {
        lock.lock()
        guard pending[key]?.generation == generation else {
            lock.unlock()
            return
        }
        let completion = pending.removeValue(forKey: key)?.completion
        lock.unlock()
        completion?(.none)
    }
}
