import Foundation

// URLProtocol 스텁 테스트들이 공유하는 헬퍼 — httpBody가 스트림으로 오는 경우(멀티파트 등)까지 읽는다.
extension URLRequest {
    var bodyData: Data? {
        httpBody ?? httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 { data.append(buffer, count: read) }
            }
            return data
        }
    }
}
