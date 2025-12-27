#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(UIKit)
typealias PlatformColor = UIColor
#else
typealias PlatformColor = NSColor
#endif

extension PlatformColor {
  var relativeLuminance: CGFloat {
    let components = self.toRGBAComponents()

    // Convert from sRGB to linear RGB
    let r = components.r < 0.04045 ? components.r / 12.92 : pow((components.r + 0.055) / 1.055, 2.4)
    let g = components.g < 0.04045 ? components.g / 12.92 : pow((components.g + 0.055) / 1.055, 2.4)
    let b = components.b < 0.04045 ? components.b / 12.92 : pow((components.b + 0.055) / 1.055, 2.4)

    // Calculate relative luminance (Y)
    let y = r * 0.2126 + g * 0.7152 + b * 0.0722

    return min(max(y, 0), 1)
  }

  func contrastRatio(to otherColor: PlatformColor) -> CGFloat {
    let luminance1 = self.relativeLuminance
    let luminance2 = otherColor.relativeLuminance
    return (max(luminance1, luminance2) + 0.05) / (min(luminance1, luminance2) + 0.05)
  }

}

extension PlatformColor {
  struct RGBAComponents {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
  }

  struct HSBComponents {
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
  }

  func toRGBAComponents() -> RGBAComponents {
    var components = RGBAComponents()

    #if canImport(UIKit)
      let result = self.getRed(
        &components.r,
        green: &components.g,
        blue: &components.b,
        alpha: &components.a
      )
      assert(result, "Failed to get RGBA components from UIColor")
    #else
      if let rgbColor = self.usingColorSpace(.sRGB) {
        rgbColor.getRed(
          &components.r,
          green: &components.g,
          blue: &components.b,
          alpha: &components.a
        )
      } else {
        assertionFailure("Failed to convert color space")
      }
    #endif

    return components
  }

  func toHSBComponents() -> HSBComponents {
    var components = HSBComponents()

    #if canImport(UIKit)
      let result = self.getHue(
        &components.h,
        saturation: &components.s,
        brightness: &components.b,
        alpha: &components.a
      )
      assert(result, "Failed to get HSB components from UIColor")
    #else
      if let rgbColor = self.usingColorSpace(.sRGB) {
        rgbColor.getHue(
          &components.h,
          saturation: &components.s,
          brightness: &components.b,
          alpha: &components.a
        )
      } else {
        assertionFailure("Failed to convert color space")
      }
    #endif

    return components
  }

  static func dynamicColor(_ block: @escaping () -> PlatformColor) -> PlatformColor {
    #if canImport(UIKit)
      #if os(watchOS)
        return block()
      #else
        return PlatformColor { _ in block() }
      #endif
    #else
      return PlatformColor(name: nil) { _ in block() }
    #endif
  }

}

extension PlatformColor {

  /// Creates a color from # prefix, alpha values, and 3 char shorthand hex values
  convenience init?(hex: String) {
    let scanner = Scanner(string: hex)
    scanner.charactersToBeSkipped = nil
    _ = scanner.scanString("#")

    switch scanner.charactersLeft() {
    case 6, 8:
      guard let red = scanner.scanHexByte(),
        let green = scanner.scanHexByte(),
        let blue = scanner.scanHexByte()
      else {
        return nil
      }
      var alpha: UInt8 = 255
      if scanner.charactersLeft() == 2 {
        guard let parsedAlpha = scanner.scanHexByte() else {
          return nil
        }

        alpha = parsedAlpha
      }

      self.init(
        red: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: CGFloat(alpha) / 255
      )
    case 3:
      guard let red = scanner.scanHexNibble(),
        let green = scanner.scanHexNibble(),
        let blue = scanner.scanHexNibble()
      else {
        return nil
      }

      self.init(
        red: CGFloat(red) / 15,
        green: CGFloat(green) / 15,
        blue: CGFloat(blue) / 15,
        alpha: 1
      )
    default:
      return nil
    }
  }

  func toHex() -> String {
    var components = self.toRGBAComponents()

    // Clamp components to [0.0, 1.0]
    components.r = max(0, min(1, components.r))
    components.g = max(0, min(1, components.g))
    components.b = max(0, min(1, components.b))
    components.a = max(0, min(1, components.a))

    if components.a == 1 {
      // RGB
      return String(
        format: "#%02lX%02lX%02lX",
        Int(round(components.r * 255)),
        Int(round(components.g * 255)),
        Int(round(components.b * 255))
      )
    } else {
      // RGBA
      return String(
        format: "#%02lX%02lX%02lX%02lX",
        Int(round(components.r * 255)),
        Int(round(components.g * 255)),
        Int(round(components.b * 255)),
        Int(round(components.a * 255))
      )
    }
  }

}

extension Scanner {

  func scanHexNibble() -> UInt8? {
    guard let character = scanCharacter(), character.isHexDigit else {
      return nil
    }

    return UInt8(String(character), radix: 16)
  }

  func scanHexByte() -> UInt8? {
    guard let highNibble = scanHexNibble(), let lowNibble = scanHexNibble() else {
      return nil
    }

    return (highNibble << 4) | lowNibble
  }

  func charactersLeft() -> Int {
    return string.count - currentIndex.utf16Offset(in: string)
  }

}

extension PlatformColor {

  func lightening(by ratio: CGFloat) -> PlatformColor {
    return .dynamicColor {
      let components = self.toHSBComponents()
      let newBrightness =
        components.b != 0
        ? components.b + (components.b * ratio)
        : ratio

      return PlatformColor(
        hue: components.h,
        saturation: components.s,
        brightness: min(newBrightness, 1),
        alpha: components.a
      )
    }
  }

  func darkening(by ratio: CGFloat) -> PlatformColor {
    return .dynamicColor {
      let components = self.toHSBComponents()
      let newBrightness =
        components.b != 1
        ? components.b - (components.b * ratio)
        : 1 - ratio

      return PlatformColor(
        hue: components.h,
        saturation: components.s,
        brightness: max(newBrightness, 0),
        alpha: components.a
      )
    }
  }

}

#if canImport(SwiftUI)
  import SwiftUI

  @available(macOS 11.0, iOS 14.0, tvOS 14.0, macCatalyst 14.0, watchOS 7.0, *)
  extension Color {

    var relativeLuminance: CGFloat {
      PlatformColor(self).relativeLuminance
    }

    init?(hex: String) {
      guard let color = PlatformColor(hex: hex) else {
        return nil
      }

      self.init(color)
    }

    func toHex() -> String {
      return PlatformColor(self).toHex()
    }

    func contrastRatio(to otherColor: Color) -> CGFloat {
      return PlatformColor(self).contrastRatio(to: PlatformColor(otherColor))
    }

    func lightening(by ratio: CGFloat) -> Color {
      return Color(
        PlatformColor(self).lightening(by: ratio)
      )
    }

    func darkening(by ratio: CGFloat) -> Color {
      return Color(
        PlatformColor(self).darkening(by: ratio)
      )
    }

  }
#endif
