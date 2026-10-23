import Foundation

enum URLRequestTestBodyError: Error {
    case unreadableStream
}

extension URLRequest {
    func materializingHTTPBodyForTesting() throws -> URLRequest {
        guard httpBody == nil, let stream = httpBodyStream else {
            return self
        }

        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead > 0 {
                body.append(contentsOf: buffer.prefix(bytesRead))
            } else if bytesRead == 0 {
                break
            } else {
                throw stream.streamError ?? URLRequestTestBodyError.unreadableStream
            }
        }

        var materialized = self
        materialized.httpBodyStream = nil
        materialized.httpBody = body
        return materialized
    }
}
