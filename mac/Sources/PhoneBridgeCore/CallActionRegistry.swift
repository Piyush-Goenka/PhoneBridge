import Foundation

public enum CallAction: String {
    case reject
    case silence
    case none
}

public final class CallActionRegistry {
    private let lock = NSLock()
    private var pending: [String: (generation: UInt64, completion: (CallAction) -> Void)] = [:]
    private var nextGeneration: UInt64 = 0
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 45) {
        self.timeout = timeout
    }

    public func register(key: String, completion: @escaping (CallAction) -> Void) {
        lock.lock()
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
        let completion = pending.removeValue(forKey: key)?.completion
        lock.unlock()
        completion?(action)
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
