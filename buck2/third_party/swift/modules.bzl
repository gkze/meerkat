# @generated from each package's manifest at its pinned revision. Do not edit;
# run: buck2 run //buck2/third_party/swift:regenerate

TRAITS = {
  "swift-custom-dump" : [
    "FoundationNetworking"
  ],
  "swift-dependencies" : [
    "Clocks",
    "CombineSchedulers",
    "Foundation",
    "FoundationNetworking"
  ],
  "swift-sharing" : [
    "CustomDump",
    "IdentifiedCollections"
  ]
}

MINIMUM_MACOS = {
  "codeeditlanguages" : "13.0",
  "codeeditsourceeditor" : "13.0",
  "codeeditsymbols" : "12.0",
  "codeedittextview" : "13.0",
  "combine-schedulers" : "12.0",
  "eventsource" : "12.0",
  "grdb.swift" : "10.15",
  "jsonrpc" : "10.15",
  "languageserverprotocol" : "10.15",
  "rearrange" : "10.13",
  "sqlite-data" : "13.0",
  "swift-argument-parser" : "10.13",
  "swift-clocks" : "12.0",
  "swift-collections" : "10.13",
  "swift-concurrency-extras" : "10.15",
  "swift-custom-dump" : "12.0",
  "swift-dependencies" : "12.0",
  "swift-identified-collections" : "10.13",
  "swift-issue-reporting" : "10.15",
  "swift-log" : "10.13",
  "swift-perception" : "12.0",
  "swift-sdk" : "13.0",
  "swift-sharing" : "12.0",
  "swift-structured-queries" : "13.0",
  "swift-syntax" : "10.15",
  "swift-system" : "10.13",
  "swifttreesitter" : "10.13",
  "textformation" : "10.15",
  "textstory" : "10.15",
  "tree-sitter" : "10.13"
}

MODULES = {
  "ArgumentParser" : {
    "deps" : [
      "ArgumentParserToolInfo"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-argument-parser",
    "path" : "Sources/ArgumentParser"
  },
  "ArgumentParserToolInfo" : {
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-argument-parser",
    "path" : "Sources/ArgumentParserToolInfo"
  },
  "BitCollections" : {
    "defines" : [
      "COLLECTIONS_RANDOMIZED_TESTING"
    ],
    "deps" : [
      "InternalCollectionsUtilities"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "experimental_features" : [
      "AvailabilityMacro=SwiftStdlib 5.0: macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2",
      "AvailabilityMacro=SwiftStdlib 5.1: macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0",
      "AvailabilityMacro=SwiftStdlib 5.6: macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4",
      "AvailabilityMacro=SwiftStdlib 5.7: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0",
      "AvailabilityMacro=SwiftStdlib 5.8: macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4",
      "AvailabilityMacro=SwiftStdlib 5.9: macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0",
      "AvailabilityMacro=SwiftStdlib 5.10: macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1",
      "AvailabilityMacro=SwiftStdlib 6.0: macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
      "AvailabilityMacro=SwiftStdlib 6.1: macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4",
      "AvailabilityMacro=SwiftStdlib 6.2: macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0",
      "AvailabilityMacro=SwiftStdlib 6.3: macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4",
      "AvailabilityMacro=SwiftStdlib 6.4: macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0",
      "AvailabilityMacro=SwiftStdlib 6.5: macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999",
      "BuiltinModule",
      "Lifetimes",
      "InoutLifetimeDependence",
      "AddressableParameters",
      "AddressableTypes",
      "SuppressedAssociatedTypesWithDefaults"
    ],
    "kind" : "library",
    "package" : "swift-collections",
    "path" : "Sources/BitCollections",
    "swift_flags" : [
      "-strict-memory-safety"
    ],
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "CSystem" : {
    "kind" : "c",
    "package" : "swift-system",
    "path" : "Sources/CSystem",
    "srcs" : [
      "shims.c"
    ]
  },
  "Clocks" : {
    "deps" : [
      "ConcurrencyExtras",
      "IssueReporting"
    ],
    "kind" : "library",
    "package" : "swift-clocks",
    "path" : "Sources/Clocks",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "CodeEditLanguages" : {
    "deps" : [
      "CodeLanguagesContainer",
      "SwiftTreeSitter"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "linked_libraries" : [
      "c++"
    ],
    "package" : "codeeditlanguages",
    "path" : "Sources/CodeEditLanguages",
    "resources" : [
      {
        "path" : "Resources",
        "rule" : "copy"
      }
    ]
  },
  "CodeEditSourceEditor" : {
    "deps" : [
      "CodeEditTextView",
      "CodeEditLanguages",
      "TextFormation",
      "CodeEditSymbols"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "package" : "codeeditsourceeditor",
    "path" : "Sources/CodeEditSourceEditor"
  },
  "CodeEditSymbols" : {
    "kind" : "library",
    "language_mode" : "5",
    "package" : "codeeditsymbols",
    "path" : "Sources/CodeEditSymbols",
    "resources" : [
      {
        "path" : "Symbols.xcassets",
        "rule" : "process"
      }
    ]
  },
  "CodeEditTextView" : {
    "deps" : [
      "TextStory",
      "Collections",
      "CodeEditTextViewObjC"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "package" : "codeedittextview",
    "path" : "Sources/CodeEditTextView"
  },
  "CodeEditTextViewObjC" : {
    "kind" : "c",
    "package" : "codeedittextview",
    "path" : "Sources/CodeEditTextViewObjC",
    "srcs" : [
      "CGContextHidden.m"
    ]
  },
  "CodeLanguagesContainer" : {
    "kind" : "binary",
    "package" : "codeeditlanguages",
    "path" : "CodeLanguagesContainer.xcframework.zip"
  },
  "Collections" : {
    "defines" : [
      "COLLECTIONS_RANDOMIZED_TESTING"
    ],
    "deps" : [
      "BitCollections",
      "DequeModule",
      "HashTreeCollections",
      "HeapModule",
      "OrderedCollections",
      "_RopeModule"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "experimental_features" : [
      "AvailabilityMacro=SwiftStdlib 5.0: macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2",
      "AvailabilityMacro=SwiftStdlib 5.1: macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0",
      "AvailabilityMacro=SwiftStdlib 5.6: macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4",
      "AvailabilityMacro=SwiftStdlib 5.7: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0",
      "AvailabilityMacro=SwiftStdlib 5.8: macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4",
      "AvailabilityMacro=SwiftStdlib 5.9: macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0",
      "AvailabilityMacro=SwiftStdlib 5.10: macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1",
      "AvailabilityMacro=SwiftStdlib 6.0: macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
      "AvailabilityMacro=SwiftStdlib 6.1: macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4",
      "AvailabilityMacro=SwiftStdlib 6.2: macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0",
      "AvailabilityMacro=SwiftStdlib 6.3: macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4",
      "AvailabilityMacro=SwiftStdlib 6.4: macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0",
      "AvailabilityMacro=SwiftStdlib 6.5: macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999",
      "BuiltinModule",
      "Lifetimes",
      "InoutLifetimeDependence",
      "AddressableParameters",
      "AddressableTypes",
      "SuppressedAssociatedTypesWithDefaults"
    ],
    "kind" : "library",
    "package" : "swift-collections",
    "path" : "Sources/Collections",
    "swift_flags" : [
      "-strict-memory-safety"
    ],
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "CombineSchedulers" : {
    "deps" : [
      "ConcurrencyExtras",
      "IssueReporting"
    ],
    "kind" : "library",
    "package" : "combine-schedulers",
    "path" : "Sources/CombineSchedulers",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility"
    ]
  },
  "ConcurrencyExtras" : {
    "kind" : "library",
    "package" : "swift-concurrency-extras",
    "path" : "Sources/ConcurrencyExtras",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "CustomDump" : {
    "deps" : [
      "IssueReporting"
    ],
    "kind" : "library",
    "package" : "swift-custom-dump",
    "path" : "Sources/CustomDump",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "Dependencies" : {
    "deps" : [
      "Clocks",
      "CombineSchedulers",
      "ConcurrencyExtras",
      "IssueReporting"
    ],
    "kind" : "library",
    "package" : "swift-dependencies",
    "path" : "Sources/Dependencies",
    "upcoming_features" : [
      "MemberImportVisibility",
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "DequeModule" : {
    "defines" : [
      "COLLECTIONS_RANDOMIZED_TESTING"
    ],
    "deps" : [
      "InternalCollectionsUtilities",
      "SpanPreview"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "experimental_features" : [
      "AvailabilityMacro=SwiftStdlib 5.0: macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2",
      "AvailabilityMacro=SwiftStdlib 5.1: macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0",
      "AvailabilityMacro=SwiftStdlib 5.6: macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4",
      "AvailabilityMacro=SwiftStdlib 5.7: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0",
      "AvailabilityMacro=SwiftStdlib 5.8: macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4",
      "AvailabilityMacro=SwiftStdlib 5.9: macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0",
      "AvailabilityMacro=SwiftStdlib 5.10: macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1",
      "AvailabilityMacro=SwiftStdlib 6.0: macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
      "AvailabilityMacro=SwiftStdlib 6.1: macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4",
      "AvailabilityMacro=SwiftStdlib 6.2: macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0",
      "AvailabilityMacro=SwiftStdlib 6.3: macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4",
      "AvailabilityMacro=SwiftStdlib 6.4: macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0",
      "AvailabilityMacro=SwiftStdlib 6.5: macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999",
      "BuiltinModule",
      "Lifetimes",
      "InoutLifetimeDependence",
      "AddressableParameters",
      "AddressableTypes",
      "SuppressedAssociatedTypesWithDefaults"
    ],
    "kind" : "library",
    "package" : "swift-collections",
    "path" : "Sources/DequeModule",
    "swift_flags" : [
      "-strict-memory-safety"
    ],
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "EventSource" : {
    "kind" : "library",
    "package" : "eventsource",
    "path" : "Sources/EventSource"
  },
  "GRDB" : {
    "defines" : [
      "SQLITE_ENABLE_FTS5",
      "SQLITE_ENABLE_SNAPSHOT"
    ],
    "deps" : [
      "GRDBSQLite"
    ],
    "kind" : "library",
    "package" : "grdb.swift",
    "path" : "GRDB",
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "GRDBSQLite" : {
    "kind" : "system",
    "package" : "grdb.swift",
    "path" : "Sources/GRDBSQLite"
  },
  "HashTreeCollections" : {
    "defines" : [
      "COLLECTIONS_RANDOMIZED_TESTING"
    ],
    "deps" : [
      "InternalCollectionsUtilities"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "experimental_features" : [
      "AvailabilityMacro=SwiftStdlib 5.0: macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2",
      "AvailabilityMacro=SwiftStdlib 5.1: macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0",
      "AvailabilityMacro=SwiftStdlib 5.6: macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4",
      "AvailabilityMacro=SwiftStdlib 5.7: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0",
      "AvailabilityMacro=SwiftStdlib 5.8: macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4",
      "AvailabilityMacro=SwiftStdlib 5.9: macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0",
      "AvailabilityMacro=SwiftStdlib 5.10: macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1",
      "AvailabilityMacro=SwiftStdlib 6.0: macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
      "AvailabilityMacro=SwiftStdlib 6.1: macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4",
      "AvailabilityMacro=SwiftStdlib 6.2: macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0",
      "AvailabilityMacro=SwiftStdlib 6.3: macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4",
      "AvailabilityMacro=SwiftStdlib 6.4: macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0",
      "AvailabilityMacro=SwiftStdlib 6.5: macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999",
      "BuiltinModule",
      "Lifetimes",
      "InoutLifetimeDependence",
      "AddressableParameters",
      "AddressableTypes",
      "SuppressedAssociatedTypesWithDefaults"
    ],
    "kind" : "library",
    "package" : "swift-collections",
    "path" : "Sources/HashTreeCollections",
    "swift_flags" : [
      "-strict-memory-safety"
    ],
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "HeapModule" : {
    "defines" : [
      "COLLECTIONS_RANDOMIZED_TESTING"
    ],
    "deps" : [
      "InternalCollectionsUtilities"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "experimental_features" : [
      "AvailabilityMacro=SwiftStdlib 5.0: macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2",
      "AvailabilityMacro=SwiftStdlib 5.1: macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0",
      "AvailabilityMacro=SwiftStdlib 5.6: macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4",
      "AvailabilityMacro=SwiftStdlib 5.7: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0",
      "AvailabilityMacro=SwiftStdlib 5.8: macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4",
      "AvailabilityMacro=SwiftStdlib 5.9: macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0",
      "AvailabilityMacro=SwiftStdlib 5.10: macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1",
      "AvailabilityMacro=SwiftStdlib 6.0: macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
      "AvailabilityMacro=SwiftStdlib 6.1: macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4",
      "AvailabilityMacro=SwiftStdlib 6.2: macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0",
      "AvailabilityMacro=SwiftStdlib 6.3: macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4",
      "AvailabilityMacro=SwiftStdlib 6.4: macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0",
      "AvailabilityMacro=SwiftStdlib 6.5: macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999",
      "BuiltinModule",
      "Lifetimes",
      "InoutLifetimeDependence",
      "AddressableParameters",
      "AddressableTypes",
      "SuppressedAssociatedTypesWithDefaults"
    ],
    "kind" : "library",
    "package" : "swift-collections",
    "path" : "Sources/HeapModule",
    "swift_flags" : [
      "-strict-memory-safety"
    ],
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "IdentifiedCollections" : {
    "deps" : [
      "OrderedCollections"
    ],
    "kind" : "library",
    "package" : "swift-identified-collections",
    "path" : "Sources/IdentifiedCollections"
  },
  "Internal" : {
    "headers" : [
      "TSYTextStorage.h"
    ],
    "include" : ".",
    "kind" : "c",
    "package" : "textstory",
    "path" : "Sources/Internal",
    "srcs" : [
      "TSYTextStorage.m"
    ]
  },
  "InternalCollectionsUtilities" : {
    "defines" : [
      "COLLECTIONS_RANDOMIZED_TESTING"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "experimental_features" : [
      "AvailabilityMacro=SwiftStdlib 5.0: macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2",
      "AvailabilityMacro=SwiftStdlib 5.1: macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0",
      "AvailabilityMacro=SwiftStdlib 5.6: macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4",
      "AvailabilityMacro=SwiftStdlib 5.7: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0",
      "AvailabilityMacro=SwiftStdlib 5.8: macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4",
      "AvailabilityMacro=SwiftStdlib 5.9: macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0",
      "AvailabilityMacro=SwiftStdlib 5.10: macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1",
      "AvailabilityMacro=SwiftStdlib 6.0: macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
      "AvailabilityMacro=SwiftStdlib 6.1: macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4",
      "AvailabilityMacro=SwiftStdlib 6.2: macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0",
      "AvailabilityMacro=SwiftStdlib 6.3: macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4",
      "AvailabilityMacro=SwiftStdlib 6.4: macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0",
      "AvailabilityMacro=SwiftStdlib 6.5: macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999",
      "BuiltinModule",
      "Lifetimes",
      "InoutLifetimeDependence",
      "AddressableParameters",
      "AddressableTypes",
      "SuppressedAssociatedTypesWithDefaults"
    ],
    "kind" : "library",
    "package" : "swift-collections",
    "path" : "Sources/InternalCollectionsUtilities",
    "swift_flags" : [
      "-strict-memory-safety"
    ],
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "IssueReporting" : {
    "kind" : "library",
    "package" : "swift-issue-reporting",
    "path" : "Sources/IssueReporting",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "JSONRPC" : {
    "experimental_features" : [
      "StrictConcurrency"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "package" : "jsonrpc",
    "path" : "Sources/JSONRPC"
  },
  "LanguageServerProtocol" : {
    "deps" : [
      "JSONRPC"
    ],
    "experimental_features" : [
      "StrictConcurrency"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "package" : "languageserverprotocol",
    "path" : "Sources/LanguageServerProtocol"
  },
  "Logging" : {
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-log",
    "path" : "Sources/Logging",
    "swift_flags" : [
      "-Xfrontend",
      "-require-explicit-sendable"
    ],
    "upcoming_features" : [
      "ExistentialAny",
      "MemberImportVisibility",
      "InternalImportsByDefault",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "MCP" : {
    "deps" : [
      "SystemPackage",
      "Logging",
      "EventSource"
    ],
    "kind" : "library",
    "package" : "swift-sdk",
    "path" : "Sources/MCP",
    "upcoming_features" : [
      "StrictConcurrency"
    ]
  },
  "OrderedCollections" : {
    "defines" : [
      "COLLECTIONS_RANDOMIZED_TESTING"
    ],
    "deps" : [
      "InternalCollectionsUtilities"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "experimental_features" : [
      "AvailabilityMacro=SwiftStdlib 5.0: macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2",
      "AvailabilityMacro=SwiftStdlib 5.1: macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0",
      "AvailabilityMacro=SwiftStdlib 5.6: macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4",
      "AvailabilityMacro=SwiftStdlib 5.7: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0",
      "AvailabilityMacro=SwiftStdlib 5.8: macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4",
      "AvailabilityMacro=SwiftStdlib 5.9: macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0",
      "AvailabilityMacro=SwiftStdlib 5.10: macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1",
      "AvailabilityMacro=SwiftStdlib 6.0: macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
      "AvailabilityMacro=SwiftStdlib 6.1: macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4",
      "AvailabilityMacro=SwiftStdlib 6.2: macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0",
      "AvailabilityMacro=SwiftStdlib 6.3: macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4",
      "AvailabilityMacro=SwiftStdlib 6.4: macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0",
      "AvailabilityMacro=SwiftStdlib 6.5: macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999",
      "BuiltinModule",
      "Lifetimes",
      "InoutLifetimeDependence",
      "AddressableParameters",
      "AddressableTypes",
      "SuppressedAssociatedTypesWithDefaults"
    ],
    "kind" : "library",
    "package" : "swift-collections",
    "path" : "Sources/OrderedCollections",
    "swift_flags" : [
      "-strict-memory-safety"
    ],
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "Perception" : {
    "deps" : [
      "PerceptionCore"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "macros" : [
      "PerceptionMacros"
    ],
    "package" : "swift-perception",
    "path" : "Sources/Perception",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "PerceptionCore" : {
    "deps" : [
      "IssueReporting"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "package" : "swift-perception",
    "path" : "Sources/PerceptionCore",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "PerceptionMacros" : {
    "deps" : [
      "SwiftSyntaxMacros",
      "SwiftCompilerPlugin"
    ],
    "kind" : "macro",
    "language_mode" : "5",
    "package" : "swift-perception",
    "path" : "Sources/PerceptionMacros",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "Rearrange" : {
    "experimental_features" : [
      "StrictConcurrency"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "package" : "rearrange",
    "path" : "Sources/Rearrange"
  },
  "SQLiteData" : {
    "deps" : [
      "ConcurrencyExtras",
      "Dependencies",
      "GRDB",
      "IssueReporting",
      "OrderedCollections",
      "Perception",
      "Sharing",
      "StructuredQueriesSQLite"
    ],
    "kind" : "library",
    "package" : "sqlite-data",
    "path" : "Sources/SQLiteData",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "NonisolatedNonsendingByDefault",
      "InternalImportsByDefault",
      "MemberImportVisibility"
    ]
  },
  "Sharing" : {
    "deps" : [
      "Sharing1",
      "Sharing2",
      "ConcurrencyExtras",
      "CustomDump",
      "Dependencies",
      "IdentifiedCollections",
      "IssueReporting",
      "PerceptionCore"
    ],
    "kind" : "library",
    "package" : "swift-sharing",
    "path" : "Sources/Sharing",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "Sharing1" : {
    "kind" : "library",
    "package" : "swift-sharing",
    "path" : "Sources/VersionMarkerModules/Sharing1",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "Sharing2" : {
    "kind" : "library",
    "package" : "swift-sharing",
    "path" : "Sources/VersionMarkerModules/Sharing2",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "SpanPreview" : {
    "defines" : [
      "COLLECTIONS_RANDOMIZED_TESTING"
    ],
    "deps" : [
      "InternalCollectionsUtilities"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "experimental_features" : [
      "AvailabilityMacro=SwiftStdlib 5.0: macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2",
      "AvailabilityMacro=SwiftStdlib 5.1: macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0",
      "AvailabilityMacro=SwiftStdlib 5.6: macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4",
      "AvailabilityMacro=SwiftStdlib 5.7: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0",
      "AvailabilityMacro=SwiftStdlib 5.8: macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4",
      "AvailabilityMacro=SwiftStdlib 5.9: macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0",
      "AvailabilityMacro=SwiftStdlib 5.10: macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1",
      "AvailabilityMacro=SwiftStdlib 6.0: macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
      "AvailabilityMacro=SwiftStdlib 6.1: macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4",
      "AvailabilityMacro=SwiftStdlib 6.2: macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0",
      "AvailabilityMacro=SwiftStdlib 6.3: macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4",
      "AvailabilityMacro=SwiftStdlib 6.4: macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0",
      "AvailabilityMacro=SwiftStdlib 6.5: macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999",
      "BuiltinModule",
      "Lifetimes",
      "InoutLifetimeDependence",
      "AddressableParameters",
      "AddressableTypes",
      "SuppressedAssociatedTypesWithDefaults"
    ],
    "kind" : "library",
    "package" : "swift-collections",
    "path" : "Sources/SpanPreview",
    "swift_flags" : [
      "-strict-memory-safety"
    ],
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "StructuredQueries" : {
    "deps" : [
      "StructuredQueriesCore"
    ],
    "kind" : "library",
    "macros" : [
      "StructuredQueriesMacros"
    ],
    "package" : "swift-structured-queries",
    "path" : "Sources/StructuredQueries",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "StructuredQueriesCore" : {
    "deps" : [
      "IssueReporting"
    ],
    "exclude" : [
      "Symbolic Links/README.md"
    ],
    "kind" : "library",
    "package" : "swift-structured-queries",
    "path" : "Sources/StructuredQueriesCore",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "StructuredQueriesMacros" : {
    "deps" : [
      "SwiftCompilerPlugin",
      "SwiftSyntaxMacros"
    ],
    "exclude" : [
      "Symbolic Links/README.md"
    ],
    "kind" : "macro",
    "package" : "swift-structured-queries",
    "path" : "Sources/StructuredQueriesMacros",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "StructuredQueriesSQLite" : {
    "deps" : [
      "StructuredQueries",
      "StructuredQueriesSQLiteCore"
    ],
    "kind" : "library",
    "macros" : [
      "StructuredQueriesSQLiteMacros"
    ],
    "package" : "swift-structured-queries",
    "path" : "Sources/StructuredQueriesSQLite",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "StructuredQueriesSQLiteCore" : {
    "deps" : [
      "StructuredQueriesCore",
      "IssueReporting"
    ],
    "kind" : "library",
    "package" : "swift-structured-queries",
    "path" : "Sources/StructuredQueriesSQLiteCore",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "StructuredQueriesSQLiteMacros" : {
    "deps" : [
      "SwiftCompilerPlugin",
      "SwiftSyntaxMacros"
    ],
    "kind" : "macro",
    "package" : "swift-structured-queries",
    "path" : "Sources/StructuredQueriesSQLiteMacros",
    "upcoming_features" : [
      "ExistentialAny",
      "ImmutableWeakCaptures",
      "InferIsolatedConformances",
      "InternalImportsByDefault",
      "MemberImportVisibility",
      "NonisolatedNonsendingByDefault"
    ]
  },
  "SwiftBasicFormat" : {
    "deps" : [
      "SwiftSyntax"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftBasicFormat"
  },
  "SwiftCompilerPlugin" : {
    "deps" : [
      "SwiftCompilerPluginMessageHandling",
      "SwiftSyntaxMacros"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftCompilerPlugin"
  },
  "SwiftCompilerPluginMessageHandling" : {
    "deps" : [
      "_SwiftSyntaxCShims",
      "SwiftDiagnostics",
      "SwiftOperators",
      "SwiftParser",
      "SwiftSyntax",
      "SwiftSyntaxMacros",
      "SwiftSyntaxMacroExpansion"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftCompilerPluginMessageHandling"
  },
  "SwiftDiagnostics" : {
    "deps" : [
      "SwiftSyntax"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftDiagnostics"
  },
  "SwiftIfConfig" : {
    "deps" : [
      "SwiftSyntax",
      "SwiftSyntaxBuilder",
      "SwiftDiagnostics",
      "SwiftOperators",
      "SwiftParser"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftIfConfig"
  },
  "SwiftOperators" : {
    "deps" : [
      "SwiftDiagnostics",
      "SwiftParser",
      "SwiftSyntax"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftOperators"
  },
  "SwiftParser" : {
    "deps" : [
      "SwiftSyntax"
    ],
    "exclude" : [
      "CMakeLists.txt",
      "README.md"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftParser"
  },
  "SwiftParserDiagnostics" : {
    "deps" : [
      "SwiftBasicFormat",
      "SwiftDiagnostics",
      "SwiftParser",
      "SwiftSyntax"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftParserDiagnostics"
  },
  "SwiftSyntax" : {
    "deps" : [
      "_SwiftSyntaxCShims",
      "SwiftSyntax509",
      "SwiftSyntax510",
      "SwiftSyntax600",
      "SwiftSyntax601",
      "SwiftSyntax602",
      "SwiftSyntax603",
      "SwiftSyntax604"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftSyntax"
  },
  "SwiftSyntax509" : {
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/VersionMarkerModules/SwiftSyntax509"
  },
  "SwiftSyntax510" : {
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/VersionMarkerModules/SwiftSyntax510"
  },
  "SwiftSyntax600" : {
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/VersionMarkerModules/SwiftSyntax600"
  },
  "SwiftSyntax601" : {
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/VersionMarkerModules/SwiftSyntax601"
  },
  "SwiftSyntax602" : {
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/VersionMarkerModules/SwiftSyntax602"
  },
  "SwiftSyntax603" : {
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/VersionMarkerModules/SwiftSyntax603"
  },
  "SwiftSyntax604" : {
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/VersionMarkerModules/SwiftSyntax604"
  },
  "SwiftSyntaxBuilder" : {
    "deps" : [
      "SwiftBasicFormat",
      "SwiftParser",
      "SwiftDiagnostics",
      "SwiftParserDiagnostics",
      "SwiftSyntax"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftSyntaxBuilder"
  },
  "SwiftSyntaxMacroExpansion" : {
    "deps" : [
      "SwiftSyntax",
      "SwiftSyntaxBuilder",
      "SwiftSyntaxMacros",
      "SwiftDiagnostics",
      "SwiftOperators"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftSyntaxMacroExpansion"
  },
  "SwiftSyntaxMacros" : {
    "deps" : [
      "SwiftDiagnostics",
      "SwiftIfConfig",
      "SwiftParser",
      "SwiftSyntax",
      "SwiftSyntaxBuilder"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "kind" : "library",
    "package" : "swift-syntax",
    "path" : "Sources/SwiftSyntaxMacros"
  },
  "SwiftTreeSitter" : {
    "deps" : [
      "TreeSitter"
    ],
    "experimental_features" : [
      "StrictConcurrency"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "package" : "swifttreesitter",
    "path" : "Sources/SwiftTreeSitter"
  },
  "SystemPackage" : {
    "defines" : [
      "SYSTEM_PACKAGE_DARWIN",
      "SYSTEM_PACKAGE",
      "ENABLE_MOCKING"
    ],
    "deps" : [
      "CSystem"
    ],
    "exclude" : [
      "CMakeLists.txt",
      "IORing"
    ],
    "experimental_features" : [
      "AvailabilityMacro=System 0.0.1:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 0.0.2:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 0.0.3:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 1.1.0:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 1.1.1:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 1.2.0:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 1.2.1:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 1.3.0:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 1.3.1:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 1.3.2:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 1.4.0:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 1.7.0:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "AvailabilityMacro=System 199:macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, visionOS 1.0",
      "Lifetimes"
    ],
    "kind" : "library",
    "package" : "swift-system",
    "path" : "Sources/System"
  },
  "TextFormation" : {
    "deps" : [
      "TextStory"
    ],
    "experimental_features" : [
      "StrictConcurrency"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "package" : "textformation",
    "path" : "Sources/TextFormation"
  },
  "TextStory" : {
    "deps" : [
      "Internal",
      "Rearrange"
    ],
    "kind" : "library",
    "package" : "textstory",
    "path" : "Sources/TextStory"
  },
  "TreeSitter" : {
    "c_defines" : [
      "_POSIX_C_SOURCE=200112L",
      "_DEFAULT_SOURCE",
      "_DARWIN_C_SOURCE"
    ],
    "header_search_paths" : [
      "src"
    ],
    "headers" : [
      "tree_sitter/api.h"
    ],
    "kind" : "c",
    "package" : "tree-sitter",
    "path" : "lib",
    "srcs" : [
      "src/alloc.c",
      "src/get_changed_ranges.c",
      "src/language.c",
      "src/lexer.c",
      "src/node.c",
      "src/parser.c",
      "src/query.c",
      "src/stack.c",
      "src/subtree.c",
      "src/tree.c",
      "src/tree_cursor.c",
      "src/wasm/stdlib.c",
      "src/wasm_store.c"
    ]
  },
  "_RopeModule" : {
    "defines" : [
      "COLLECTIONS_RANDOMIZED_TESTING"
    ],
    "deps" : [
      "InternalCollectionsUtilities"
    ],
    "exclude" : [
      "CMakeLists.txt"
    ],
    "experimental_features" : [
      "AvailabilityMacro=SwiftStdlib 5.0: macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2",
      "AvailabilityMacro=SwiftStdlib 5.1: macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0",
      "AvailabilityMacro=SwiftStdlib 5.6: macOS 12.3, iOS 15.4, watchOS 8.5, tvOS 15.4",
      "AvailabilityMacro=SwiftStdlib 5.7: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0",
      "AvailabilityMacro=SwiftStdlib 5.8: macOS 13.3, iOS 16.4, watchOS 9.4, tvOS 16.4",
      "AvailabilityMacro=SwiftStdlib 5.9: macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0",
      "AvailabilityMacro=SwiftStdlib 5.10: macOS 14.4, iOS 17.4, watchOS 10.4, tvOS 17.4, visionOS 1.1",
      "AvailabilityMacro=SwiftStdlib 6.0: macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
      "AvailabilityMacro=SwiftStdlib 6.1: macOS 15.4, iOS 18.4, watchOS 11.4, tvOS 18.4, visionOS 2.4",
      "AvailabilityMacro=SwiftStdlib 6.2: macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0",
      "AvailabilityMacro=SwiftStdlib 6.3: macOS 26.4, iOS 26.4, watchOS 26.4, tvOS 26.4, visionOS 26.4",
      "AvailabilityMacro=SwiftStdlib 6.4: macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0",
      "AvailabilityMacro=SwiftStdlib 6.5: macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, visionOS 9999",
      "BuiltinModule",
      "Lifetimes",
      "InoutLifetimeDependence",
      "AddressableParameters",
      "AddressableTypes",
      "SuppressedAssociatedTypesWithDefaults"
    ],
    "kind" : "library",
    "language_mode" : "5",
    "package" : "swift-collections",
    "path" : "Sources/RopeModule",
    "swift_flags" : [
      "-strict-memory-safety"
    ],
    "upcoming_features" : [
      "MemberImportVisibility"
    ]
  },
  "_SwiftSyntaxCShims" : {
    "kind" : "c",
    "package" : "swift-syntax",
    "path" : "Sources/_SwiftSyntaxCShims",
    "srcs" : [
      "PlatformMutex.c"
    ]
  }
}
