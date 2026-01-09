#if canImport(AVFoundation)
	  import AVFoundation
	  import Tools

	  public struct VerboseError: TypedThrowsError {
	    public init(error: any Error) {
      let nserror = error as NSError
      let code = nserror.code

      #if !os(macOS)
        if let avcode = AVAudioSession.ErrorCode(rawValue: code) {
          let audioSessionError: String? =
            switch avcode {
            case AVAudioSession.ErrorCode.none:
              "Operation succeeded."
            case .mediaServicesFailed:
              """
              The app attempted to use the audio session during or after a Media Services failure. App
              should wait for a AVAudioSessionMediaServicesWereResetNotification and then rebuild all
              its state.
              """
            case .isBusy:
              "The app attempted to set its audio session inactive or change its AVAudioSessionIOType, but it is still actively playing and/or recording."
            case .incompatibleCategory:
              "The app tried to perform an operation on a session but its category does not support it. For instance, if the app calls setPreferredInputNumberOfChannels: while in a playback-only category."
            case .cannotInterruptOthers:
              "The app's audio session is non-mixable and trying to go active while in the background. This is allowed only when the app is the NowPlaying app."
            case .missingEntitlement:
              "The app does not have the required entitlements to perform an operation."
            case .siriIsRecording:
              "The app tried to do something with the audio session that is not allowed while Siri is recording."
            case .cannotStartPlaying:
              """
                The app is not allowed to start recording and/or playing, usually because of a lack of audio key in its Info.plist.  This could also happen if the app has this key but uses a category
                that can't record and/or play in the background (AVAudioSessionCategoryAmbient,
                AVAudioSessionCategorySoloAmbient, etc.).
              """
            case .cannotStartRecording:
              "The app is not allowed to start recording, usually because it is starting a mixable recording from the background and is not an Inter-App Audio app."
            case .badParam:
              "An illegal value was used for a property."
            case .insufficientPriority:
              "The app was not allowed to set the audio category because another app (Phone, etc.) is controlling it."
            case .resourceNotAvailable:
              """
              The operation failed because the device does not have sufficient hardware resources to complete the action. For example, the operation requires audio input hardware, but the
              device has no audio input available.
              """
            case .unspecified:
              "The operation failed because the associated session has been destroyed."
            case .expiredSession:
              "An unspecified error has occurred."
            case .sessionNotActive:
              "The operation failed because the session is not active."
            @unknown default:
              nil
            }
          if let audioSessionError {
            self.description = audioSessionError
            return
          }
        }
      #endif

      let osstatus: String? =
        switch OSStatus(code) {
        case kAudioFileUnspecifiedError:
          "kAudioFileUnspecifiedError"
        case kAudioFileUnsupportedFileTypeError:
          "kAudioFileUnsupportedFileTypeError"
        case kAudioFileUnsupportedDataFormatError:
          "kAudioFileUnsupportedDataFormatError"
        case kAudioFileUnsupportedPropertyError:
          "kAudioFileUnsupportedPropertyError"
        case kAudioFileBadPropertySizeError:
          "kAudioFileBadPropertySizeError"
        case kAudioFilePermissionsError:
          "kAudioFilePermissionsError"
        case kAudioFileNotOptimizedError:
          "kAudioFileNotOptimizedError"
        case kAudioFileInvalidChunkError:
          "kAudioFileInvalidChunkError"
        case kAudioFileDoesNotAllow64BitDataSizeError:
          "kAudioFileDoesNotAllow64BitDataSizeError"
        case kAudioFileInvalidPacketOffsetError:
          "kAudioFileInvalidPacketOffsetError"
        case kAudioFileInvalidFileError:
          "kAudioFileInvalidFileError"
        case kAudioFileOperationNotSupportedError:
          "kAudioFileOperationNotSupportedError"
        case kAudioFileNotOpenError:
          "kAudioFileNotOpenError"
        case kAudioFileEndOfFileError:
          "kAudioFileEndOfFileError"
        case kAudioFilePositionError:
          "kAudioFilePositionError"
        case kAudioFileFileNotFoundError:
          "kAudioFileFileNotFoundError"
        case kAudioCodecNoError:
          "kAudioCodecNoError"
        case kAudioCodecUnspecifiedError:
          "kAudioCodecUnspecifiedError"
        case kAudioCodecUnknownPropertyError:
          "kAudioCodecUnknownPropertyError"
        case kAudioCodecBadPropertySizeError:
          "kAudioCodecBadPropertySizeError"
        case kAudioCodecIllegalOperationError:
          "kAudioCodecIllegalOperationError"
        case kAudioCodecUnsupportedFormatError:
          "kAudioCodecUnsupportedFormatError"
        case kAudioCodecStateError:
          "kAudioCodecStateError"
        case kAudioCodecNotEnoughBufferSpaceError:
          "kAudioCodecNotEnoughBufferSpaceError"
        case kAudioCodecBadDataError:
          "kAudioCodecBadDataError"
        case kAUGraphErr_NodeNotFound:
          "kAUGraphErr_NodeNotFound"
        case kAUGraphErr_InvalidConnection:
          "kAUGraphErr_InvalidConnection"
        case kAUGraphErr_OutputNodeErr:
          "kAUGraphErr_OutputNodeErr"
        case kAUGraphErr_CannotDoInCurrentContext:
          "kAUGraphErr_CannotDoInCurrentContext"
        case kAUGraphErr_InvalidAudioUnit:
          "kAUGraphErr_InvalidAudioUnit"

        //***** MIDI errors
        case kMIDIInvalidClient:
          "kMIDIInvalidClient"
        case kMIDIInvalidPort:
          "kMIDIInvalidPort"
        case kMIDIWrongEndpointType:
          "kMIDIWrongEndpointType"
        case kMIDINoConnection:
          "kMIDINoConnection"
        case kMIDIUnknownEndpoint:
          "kMIDIUnknownEndpoint"
        case kMIDIUnknownProperty:
          "kMIDIUnknownProperty"
        case kMIDIWrongPropertyType:
          "kMIDIWrongPropertyType"
        case kMIDINoCurrentSetup:
          "kMIDINoCurrentSetup"
        case kMIDIMessageSendErr:
          "kMIDIMessageSendErr"
        case kMIDIServerStartErr:
          "kMIDIServerStartErr"
        case kMIDISetupFormatErr:
          "kMIDISetupFormatErr"
        case kMIDIWrongThread:
          "kMIDIWrongThread"
        case kMIDIObjectNotFound:
          "kMIDIObjectNotFound"
        case kMIDIIDNotUnique:
          "kMIDIIDNotUnique"
        case kMIDINotPermitted:
          "kMIDINotPermitted"

        //***** AudioToolbox errors
        case kAudioToolboxErr_CannotDoInCurrentContext:
          "kAudioToolboxErr_CannotDoInCurrentContext"
        case kAudioToolboxErr_EndOfTrack:
          "kAudioToolboxErr_EndOfTrack"
        case kAudioToolboxErr_IllegalTrackDestination:
          "kAudioToolboxErr_IllegalTrackDestination"
        case kAudioToolboxErr_InvalidEventType:
          "kAudioToolboxErr_InvalidEventType"
        case kAudioToolboxErr_InvalidPlayerState:
          "kAudioToolboxErr_InvalidPlayerState"
        case kAudioToolboxErr_InvalidSequenceType:
          "kAudioToolboxErr_InvalidSequenceType"
        case kAudioToolboxErr_NoSequence:
          "kAudioToolboxErr_NoSequence"
        case kAudioToolboxErr_StartOfTrack:
          "kAudioToolboxErr_StartOfTrack"
        case kAudioToolboxErr_TrackIndexError:
          "kAudioToolboxErr_TrackIndexError"
        case kAudioToolboxErr_TrackNotFound:
          "kAudioToolboxErr_TrackNotFound"
        case kAudioToolboxError_NoTrackDestination:
          "kAudioToolboxError_NoTrackDestination"

        //***** AudioUnit errors
        case kAudioUnitErr_CannotDoInCurrentContext:
          "kAudioUnitErr_CannotDoInCurrentContext"
        case kAudioUnitErr_FailedInitialization:
          "kAudioUnitErr_FailedInitialization"
        case kAudioUnitErr_FileNotSpecified:
          "kAudioUnitErr_FileNotSpecified"
        case kAudioUnitErr_FormatNotSupported:
          "kAudioUnitErr_FormatNotSupported"
        case kAudioUnitErr_IllegalInstrument:
          "kAudioUnitErr_IllegalInstrument"
        case kAudioUnitErr_Initialized:
          "kAudioUnitErr_Initialized"
        case kAudioUnitErr_InvalidElement:
          "kAudioUnitErr_InvalidElement"
        case kAudioUnitErr_InvalidFile:
          "kAudioUnitErr_InvalidFile"
        case kAudioUnitErr_InvalidOfflineRender:
          "kAudioUnitErr_InvalidOfflineRender"
        case kAudioUnitErr_InvalidParameter:
          "kAudioUnitErr_InvalidParameter"
        case kAudioUnitErr_InvalidProperty:
          "kAudioUnitErr_InvalidProperty"
        case kAudioUnitErr_InvalidPropertyValue:
          "kAudioUnitErr_InvalidPropertyValue"
        case kAudioUnitErr_InvalidScope:
          "kAudioUnitErr_InvalidScope"
        case kAudioUnitErr_InstrumentTypeNotFound:
          "kAudioUnitErr_InstrumentTypeNotFound"
        case kAudioUnitErr_NoConnection:
          "kAudioUnitErr_NoConnection"
        case kAudioUnitErr_PropertyNotInUse:
          "kAudioUnitErr_PropertyNotInUse"
        case kAudioUnitErr_PropertyNotWritable:
          "kAudioUnitErr_PropertyNotWritable"
        case kAudioUnitErr_TooManyFramesToProcess:
          "kAudioUnitErr_TooManyFramesToProcess"
        case kAudioUnitErr_Unauthorized:
          "kAudioUnitErr_Unauthorized"
        case kAudioUnitErr_Uninitialized:
          "kAudioUnitErr_Uninitialized"
        case kAudioUnitErr_UnknownFileType:
          "kAudioUnitErr_UnknownFileType"
        case kAudioUnitErr_RenderTimeout:
          "kAudioUnitErr_RenderTimeout"

        //***** AudioComponent errors
        case kAudioComponentErr_DuplicateDescription:
          "kAudioComponentErr_DuplicateDescription"
        case kAudioComponentErr_InitializationTimedOut:
          "kAudioComponentErr_InitializationTimedOut"
        case kAudioComponentErr_InstanceInvalidated:
          "kAudioComponentErr_InstanceInvalidated"
        case kAudioComponentErr_InvalidFormat:
          "kAudioComponentErr_InvalidFormat"
        case kAudioComponentErr_NotPermitted:
          "kAudioComponentErr_NotPermitted"
        case kAudioComponentErr_TooManyInstances:
          "kAudioComponentErr_TooManyInstances"
        case kAudioComponentErr_UnsupportedType:
          "kAudioComponentErr_UnsupportedType"

        //***** Audio errors
        case kAudio_BadFilePathError:
          "kAudio_BadFilePathError"
        case kAudio_FileNotFoundError:
          "kAudio_FileNotFoundError"
        case kAudio_FilePermissionError:
          "kAudio_FilePermissionError"
        case kAudio_MemFullError:
          "kAudio_MemFullError"
        case kAudio_ParamError:
          "kAudio_ParamError"
        case kAudio_TooManyFilesOpenError:
          "kAudio_TooManyFilesOpenError"
        case kAudio_UnimplementedError:
          "kAudio_UnimplementedError"
        default:
          nil
        }

      if let osstatus {
        self.description = osstatus
        return
      }

      self.description = String(describing: error)

	    }
	    public let description: String
	  }
	#endif
