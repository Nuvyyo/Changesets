//
//  Changeset.swift
//  Changesets
//
//  Created by Steve Brambilla on 2015-05-24.
//  Copyright (c) 2015 Steve Brambilla. All rights reserved.
//

import Foundation

// ----------------------------------------------------------------------------
// MARK: - Changeset

/// A Changeset represents the changes required to transition from one
/// collection to another. Typically from an older snapshot of a collection, to
/// an updated snapshot of a collection.
///
/// To apply a Changeset to an collection, apply the updated changes first, then
/// the deleted changes, followed by the inserted changes.
public struct Changeset: Equatable {
	/// An array of index ranges corresponding to updated elements, sorted in 
	/// ascending order.
	public let updated: [Range<Int>]

	/// An array of index ranges corresponding to deleted elements, sorted in
	/// ascending order.
	public let deleted: [Range<Int>]

	/// An array of index ranges corresponding to inserted elements, sorted in
	/// ascending order.
	public let inserted: [Range<Int>]

	/// The number of elements in the _before_ collection.
	public let countBefore: Int

	/// The number of elements in the _after_ collection.
	public let countAfter: Int
}

public func == (lhs: Changeset, rhs: Changeset) -> Bool {
	return lhs.inserted == rhs.inserted &&
		lhs.deleted == rhs.deleted &&
		lhs.updated == rhs.updated &&
		lhs.countBefore == rhs.countBefore &&
		lhs.countAfter == rhs.countAfter
}

extension Changeset: CustomStringConvertible {
	public var description: String {
		return "Changeset(inserted: \(inserted), deleted: \(deleted), updated: \(updated))"
	}
}

extension Changeset {
	/// Returns the total number of changed indexes in the Changeset.
	public var changedIndexesCount: Int {
		let insertedCount = inserted.reduce(0) { $0 + $1.count }
		let deletedCount = deleted.reduce(0) { $0 + $1.count }
		let updatedCount = updated.reduce(0) { $0 + $1.count }
		return insertedCount + deletedCount + updatedCount
	}

	/// Returns true if there are no changed indexes in the Changeset.
	public var isEmpty: Bool {
		return changedIndexesCount == 0
	}

	// Returns true if the before and after collections were fully replaced.
	public var wasReplaced: Bool {
		// If everything in the `before` collection is deleted or everything in
		// the after collection is inserted, then it's considered a full 
		// replacement.
		let fullDeletedRange = (0 ..< countBefore)
		if let deletedRange = deleted.first where deletedRange == fullDeletedRange {
			return true
		}

		let fullInsertedRange = (0 ..< countAfter)
		if let insertedRange = inserted.first where insertedRange == fullInsertedRange {
			return true
		}

		return false
	}

	/// Applies the changeset's modifications to the `beforeIndex` and returns
	/// the "after" index.
	///
	/// Returns nil if the `beforeIndex` was deleted as part of the changeset.
	public func afterIndexFor(beforeIndex: Int) -> Int? {
		var deletes = 0
		for deletedRange in deleted {
			// If any of the deleted ranges contains `source`, return nil.
			if deletedRange.contains(beforeIndex) {
				return nil
			}

			// Subtract all ranges that preceed the before index.
			if deletedRange.endIndex <= beforeIndex {
				deletes += deletedRange.count
			}
		}

		var position = beforeIndex - deletes

		// Walk through the inserted ranges, bumping up the 'after' position by
		// every range that would be inserted before it.
		for insertedRange in inserted {
			if insertedRange.startIndex <= position {
				position += insertedRange.count
			}
		}

		return position
	}
}

// ----------------------------------------------------------------------------
// MARK: - CollectionType Extensions

extension CollectionType where Generator.Element: Matchable, Index == Int {
	/// Calculate the Changeset required to transition from `self` to `after`.
	///
	/// Provides high-fidelity matching using Matchable's `matchWith()` method.
	public func changesetTo(after: Self) -> Changeset {
		return Changeset.calculateChangeset(from: self, to: after) { left, right in
			left.match(right)
		}
	}
}

extension CollectionType where Generator.Element: Equatable, Index == Int {
	/// Calculate the Changeset required to transition from `self` to `after`.
	///
	/// Provides low-fidelity matching by matching using value equality.
	public func changesetTo(after: Self) -> Changeset {
		return Changeset.calculateChangeset(from: self, to: after) { left, right in
			MatchResult.noIdentityCompare(left, right)
		}
	}
}

// ----------------------------------------------------------------------------
// MARK: - Calculating Changesets

extension Changeset {
	private static func calculateChangeset<T, C: CollectionType where T == C.Generator.Element, C.Index == Int>(from before: C, to after: C, match: (T, T) -> MatchResult) -> Changeset {
		// Calculate the diff between the two collections by comparing identity.
		let report = before.diff(after) { left, right in
			match(left, right) != .DifferentIdentity
		}

		// Bucket the diff result spans into inserted, deleted, and updated ranges.
		var inserted = [Range<Int>]()
		var deleted = [Range<Int>]()
		var updated = [Range<Int>]()
		for span in report {
			switch span {
			case let .NoChange(sourceIndex, destIndex, length):
				// The 'NoChange' case only considers identity differences. Do
				// another pass over these ranges to compare their values in order
				// to differentiate between unchanged instances and updated 
				// instances.
				var rangeStart: Int?
				for idx in 0 ..< length {
					let srcIdx = sourceIndex + idx
					let destIdx = destIndex + idx

					let srcVal = before[srcIdx]
					let destVal = after[destIdx]

					switch match(srcVal, destVal) {
					case .SameIdentityEqualValue:
						// Values are equal, end the current 'updated` range if needed.
						if let start = rangeStart {
							let rangeEnd = srcIdx
							let range = (start ..< rangeEnd)
							updated.append(range)
							rangeStart = nil
						}

					case .SameIdentityInequalValue:
						// Values are not equal, start a new 'updated' range if needed.
						if rangeStart == nil {
							rangeStart = srcIdx
						}

					case .DifferentIdentity:
						assertionFailure(".InequalIdentity should have been resolved in the diff.")
					}
				}

				// Done this span, end the current 'updated' range if there is one.
				if let start = rangeStart {
					let rangeEnd = sourceIndex + length
					let range = (start ..< rangeEnd)
					updated.append(range)
				}

			case let .Replace(sourceIndex, destIndex, length):
				// 'Replace' spans are analagous to a delete and an insert.
				let deleteRange = (sourceIndex ..< sourceIndex+length)
				deleted.append(deleteRange)

				let addRange = (destIndex ..< destIndex+length)
				inserted.append(addRange)

			case let .Delete(sourceIndex, length):
				// Map `Delete` spans directly to deleted ranges.
				let range = (sourceIndex ..< sourceIndex+length)
				deleted.append(range)

			case let .Add(destIndex, length):
				// Map `Add` spans directly to inserted ranges.
				let range = (destIndex ..< destIndex+length)
				inserted.append(range)
			}
		}

		// Clean up the ranges by consolidating consecutive ranges together, then 
		// determine if the changeset was a full replacement.
		let consolidatedUpdates = consolidate(updated)
		let consolidatedDeletes = consolidate(deleted)
		let consolidatedInserts = consolidate(inserted)
		return Changeset(
			updated: consolidatedUpdates,
			deleted: consolidatedDeletes,
			inserted: consolidatedInserts,
			countBefore: before.count,
			countAfter: after.count
		)
	}

	/// Flattens consecutive ranges together and returns a consolidated array of
	/// ranges.
	private static func consolidate<T>(ranges: [Range<T>]) -> [Range<T>] {
		var consolidated = [Range<T>]()
		for current in ranges {
			if let last = consolidated.last where last.endIndex == current.startIndex {
				let flattened = (last.startIndex ..< current.endIndex)
				consolidated.removeLast()
				consolidated.append(flattened)
			} else {
				consolidated.append(current)
			}
		}
		return consolidated
	}
}
