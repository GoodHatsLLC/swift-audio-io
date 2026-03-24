// © GoodHatsLLC

#if os(iOS)
  extension AudioEnvironmentManager {
    package struct AudioDeviceChangeSummary: Equatable, CustomStringConvertible {
      let addedInputs: [AudioInput]
      let removedInputs: [AudioInput]
      let addedSources: [AudioSource]
      let removedSources: [AudioSource]

      init(
        previousInputs: [AudioInput],
        currentInputs: [AudioInput],
        previousSources: [AudioSource],
        currentSources: [AudioSource],
      ) {
        let previousInputSet = Set(previousInputs)
        let currentInputSet = Set(currentInputs)

        addedInputs = currentInputSet.subtracting(previousInputSet).sorted()
        removedInputs = previousInputSet.subtracting(currentInputSet).sorted()

        let previousSourceSet = Set(previousSources)
        let currentSourceSet = Set(currentSources)

        addedSources = currentSourceSet.subtracting(previousSourceSet).sorted()
        removedSources = previousSourceSet.subtracting(currentSourceSet).sorted()
      }

      var description: String {
        let inputsDescription =
          "inputs + [\(addedInputs)], - [\(removedInputs)]"
        let sourcesDescription =
          "sources + [\(addedSources)], - [\(removedSources)]"
        return "\(inputsDescription), \(sourcesDescription)"
      }
    }
  }
#endif
