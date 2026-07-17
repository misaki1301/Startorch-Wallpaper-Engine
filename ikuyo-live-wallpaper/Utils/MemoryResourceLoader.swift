import AVFoundation
import UniformTypeIdentifiers

final class MemoryResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let data: Data
    private let contentType: String

    init(data: Data, fileExtension: String) {
        self.data = data
        self.contentType = UTType(filenameExtension: fileExtension)?.identifier ?? AVFileType.mp4.rawValue
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let contentRequest = loadingRequest.contentInformationRequest {
            contentRequest.contentType = contentType
            contentRequest.contentLength = Int64(data.count)
            contentRequest.isByteRangeAccessSupported = true
        }

        if let dataRequest = loadingRequest.dataRequest {
            let dataLength = data.count
            let offset = Int(dataRequest.requestedOffset)
            let length = dataRequest.requestedLength > 0
                ? min(dataRequest.requestedLength, dataLength - offset)
                : dataLength - offset

            guard offset >= 0, offset < dataLength, length > 0 else {
                loadingRequest.finishLoading(with: NSError(domain: "MemoryResourceLoader", code: -1))
                return true
            }

            dataRequest.respond(with: data[offset..<offset + length])
            loadingRequest.finishLoading()
        }

        return true
    }
}
