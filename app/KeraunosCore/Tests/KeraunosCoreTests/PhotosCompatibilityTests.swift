import Testing
import Foundation
import KeraunosCore

struct PhotosCompatibilityTests {
    @Test func acceptsPhotosVideoContainers() {
        for ext in ["mp4", "m4v", "mov", "MP4", "MOV"] {
            #expect(PhotosCompatibility.canSave(URL(fileURLWithPath: "/tmp/clip.\(ext)")))
        }
    }

    @Test func rejectsNonPhotosContainersAndSidecars() {
        for ext in ["mkv", "webm", "txt", "log"] {
            #expect(!PhotosCompatibility.canSave(URL(fileURLWithPath: "/tmp/clip.\(ext)")))
        }
        #expect(!PhotosCompatibility.canSave(URL(fileURLWithPath: "/tmp/noextension")))
    }
}
