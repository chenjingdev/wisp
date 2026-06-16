import CoreAudio
import Foundation

/// 녹음 동안 시스템 기본 출력 장치의 볼륨을 낮추거나(duck) 음소거(mute)하고,
/// 끝나면 원래 볼륨으로 복원한다. 볼륨 제어를 지원하지 않는 장치면 무동작(안전).
@MainActor
final class AudioOutputController {
    /// 첫 억제 시점의 (장치, 볼륨). restore에서 같은 장치로 되돌린다 — 녹음 중
    /// 사용자가 출력 장치를 바꿔도 원래 장치의 볼륨이 복원되도록 deviceID를 함께 잡는다.
    private var saved: (device: AudioDeviceID, volume: Float32)?

    /// 현재 볼륨을 저장하고 target(0…1)으로 낮춘다. 이미 억제 중이면 저장값 유지.
    func suppress(to target: Float) {
        guard let device = Self.defaultOutputDevice() else { return }
        if saved == nil, let current = Self.volume(device) {
            saved = (device, current)
        }
        Self.setVolume(device, Float32(max(0, min(1, target))))
    }

    /// 저장해 둔 장치·볼륨으로 복원. 멱등.
    func restore() {
        guard let saved else { return }
        Self.setVolume(saved.device, saved.volume)
        self.saved = nil
    }

    // MARK: - CoreAudio

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID
        )
        return status == noErr && devID != 0 ? devID : nil
    }

    private static func volumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    /// main element 우선, 없으면 채널 1·2에서 읽는다.
    private static func volume(_ dev: AudioDeviceID) -> Float32? {
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = volumeAddress(element: element)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var vol = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        return nil
    }

    /// 설정 가능한 모든 요소(main/채널)에 볼륨을 적용한다.
    private static func setVolume(_ dev: AudioDeviceID, _ value: Float32) {
        var v = value
        let size = UInt32(MemoryLayout<Float32>.size)
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = volumeAddress(element: element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(dev, &addr),
                  AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
                  settable.boolValue
            else { continue }
            AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &v)
        }
    }
}
