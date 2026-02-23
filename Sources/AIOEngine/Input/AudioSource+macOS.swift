#if os(macOS)
  public import Foundation
  public import Tools

  public struct AudioSource: Hashable, Sendable, Identifiable, CustomStringConvertible, Comparable {
    public enum PreferenceError: AudioError {
      case unsupportedOperation

      public var description: String {
        "Audio source preference changes are not supported on this platform"
      }
    }

    public init(
      id: String = UUID().uuidString,
      name: String,
      supportedPolarPatterns: [PolarPattern] = []
    ) {
      self.id = id
      self.name = name
      self.supportedPolarPatterns = supportedPolarPatterns
    }

    public let id: String
    public let name: String
    public let supportedPolarPatterns: [PolarPattern]

    public var description: String {
      name
    }

    public var hasStereo: Bool {
      supportedPolarPatterns.contains(.stereo)
    }

    public func set(preferredPolarPattern: PolarPattern) throws(PreferenceError) {
      guard supportedPolarPatterns.contains(preferredPolarPattern) else {
        throw .unsupportedOperation
      }
    }

    public static func < (lhs: AudioSource, rhs: AudioSource) -> Bool {
      lhs.name < rhs.name
    }
  }

  public struct PolarPattern: Hashable, Sendable, Identifiable {
    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }

    public let id: String
    public let name: String

    public static let omnidirectional = PolarPattern(id: "omnidirectional", name: "Omnidirectional")
    public static let cardioid = PolarPattern(id: "cardioid", name: "Cardioid")
    public static let subcardioid = PolarPattern(id: "subcardioid", name: "Subcardioid")
    public static let stereo = PolarPattern(id: "stereo", name: "Stereo")
  }
#endif
