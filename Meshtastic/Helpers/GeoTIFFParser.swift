//
//  GeoTIFFParser.swift
//  Meshtastic
//
//  Created by Benjamin Faershtein on 10/21/25.
//

import Foundation
import TIFF
import CoreLocation
import UIKit

/// Enum for common GeoTIFF errors.
enum GeoTIFFError: Error, LocalizedError {
	case invalidTIFF
	case noGeoKeys
	case invalidGeoTransform
	case unsupportedBandCount(Int32)
	case unsupportedDataType
	case missingRasterData
	case missingGeoreferencing
	case imageCreationFailed
	
	var errorDescription: String? {
		switch self {
		case .invalidTIFF: return "Invalid TIFF file."
		case .noGeoKeys: return "No GeoTIFF keys found."
		case .invalidGeoTransform: return "Invalid geotransform matrix."
		case .unsupportedBandCount(let count): return "Unsupported band count: \(count). Only single-band supported."
		case .unsupportedDataType: return "Unsupported data type."
		case .missingRasterData: return "Could not extract raster data."
		case .missingGeoreferencing: return "Missing georeferencing information (ModelTiepoint or ModelTransformation)."
		case .imageCreationFailed: return "Failed to create image from raster data."
		}
	}
}

/// Represents parsed GeoTIFF metadata and data for map overlay.
struct ParsedGeoTIFF {
	let originalName: String
	let fileSize: UInt64
	let rasterWidth: Int
	let rasterHeight: Int
	let geoTransform: [Double] // [originX, pixelWidthX, shearX, originY, shearY, pixelHeightY]
	let projection: String? // WKT or EPSG stub
	let rasterData: Data
	let rasterImage: UIImage?
	let overlayCount: Int
	let bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
	
	var coordinate: CLLocationCoordinate2D {
		let centerLat = (bounds.minLat + bounds.maxLat) / 2
		let centerLon = (bounds.minLon + bounds.maxLon) / 2
		return CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
	}
}

/// Parser for GeoTIFF files
class GeoTIFFParser {
	
	// TIFF tag constants
	private static let ColorMapTag: UInt16 = 320
	private static let ModelPixelScaleTag: UInt16 = 33550
	private static let ModelTiepointTag: UInt16 = 33922
	private static let GeoAsciiParamsTag: UInt16 = 34737
	
	/// Parse GeoTIFF
	static func parse(from url: URL) throws -> ParsedGeoTIFF {
		let data = try Data(contentsOf: url)
		guard let tiffImage = TIFFReader.readTiff(from: data) else {
			throw GeoTIFFError.invalidTIFF
		}
		guard let directories = tiffImage.fileDirectories(), !directories.isEmpty else {
			throw GeoTIFFError.invalidTIFF
		}
		let directory = directories[0]
		guard let rasters = directory.readRasters() else {
			throw GeoTIFFError.missingRasterData
		}
		
		let width = Int(rasters.width())
		let height = Int(rasters.height())
		let samplesPerPixel = Int(rasters.samplesPerPixel())
		
		// Parse TIFF tags manually
		let tags = try parseTIFFTags(from: data)
		print("Parsed TIFF tags: \(tags.keys)")
		
		// --- Extract georeferencing safely ---
		guard let pixelScaleTag = tags[ModelPixelScaleTag],
			  let tiepointTag = tags[ModelTiepointTag] else {
			print("Missing georeferencing tags")
			throw GeoTIFFError.missingGeoreferencing
		}
		
		guard let pixelScale = readDoubles(tagValue: pixelScaleTag, expectedCount: 3),
			  let tiepoint = readDoubles(tagValue: tiepointTag, expectedCount: 6) else {
			print("Failed to read pixelScale or tiepoint as doubles")
			throw GeoTIFFError.missingGeoreferencing
		}
		
		let originX = tiepoint[3]
		let originY = tiepoint[4]
		let pixelWidth = pixelScale[0]
		let pixelHeight = -pixelScale[1]
		
		let geoTransform = [originX, pixelWidth, 0.0, originY, 0.0, pixelHeight]
		
		let bounds = calculateBounds(geoTransform: geoTransform, width: width, height: height)
		print("GeoTIFF bounds: \(bounds)")
		
		let projection = tags[GeoAsciiParamsTag] as? String
		
		let (pixelData, rasterImage) = try extractRasterDataAndImage(from: directory, rasters: rasters, tags: tags)
		
		return ParsedGeoTIFF(
			originalName: url.lastPathComponent,
			fileSize: UInt64(data.count),
			rasterWidth: width,
			rasterHeight: height,
			geoTransform: geoTransform,
			projection: projection,
			rasterData: pixelData,
			rasterImage: rasterImage,
			overlayCount: 1,
			bounds: bounds
		)
	}
	
	// MARK: - Raster Extraction
	
	private static func extractRasterDataAndImage(from directory: TIFFFileDirectory, rasters: TIFFRasters, tags: [UInt16: Any]) throws -> (Data, UIImage?) {
		let width = Int(rasters.width())
		let height = Int(rasters.height())
		let samplesPerPixel = Int(rasters.samplesPerPixel())
		
		print("Image dimensions: \(width)x\(height), samplesPerPixel: \(samplesPerPixel)")
		
		guard let samplesAny = rasters.sampleValues() else {
			throw GeoTIFFError.missingRasterData
		}

		// Convert Any array to NSNumber safely
		let samples: [NSNumber] = samplesAny.flatMap { $0 }.compactMap { element in
			if let n = element as? NSNumber {
				return n
			}
			if let d = element as? Double {
				return NSNumber(value: d)
			}
			if let i = element as? Int {
				return NSNumber(value: i)
			}
			return nil
		}

		print("Total samples: \(samples.count), expected: \(width * height * samplesPerPixel)")
		
		if samples.isEmpty {
			throw GeoTIFFError.imageCreationFailed
		}
		
		let hasColorMap = tags[ColorMapTag] != nil
		if hasColorMap, let colorMapData = tags[ColorMapTag] as? Data {
			print("Using paletted image with color map, size: \(colorMapData.count) bytes")
			return try createPalettedImage(samples: samples, width: width, height: height, colorMap: colorMapData, isLittleEndian: true, transparentIndex: 0)
		} else if samplesPerPixel == 3 || samplesPerPixel == 4 {
			print("Using RGB image")
			return try createRGBImage(samples: samples, width: width, height: height)
		} else if samplesPerPixel == 1 {
			print("Using grayscale image")
			return try createGrayscaleImage(samples: samples, width: width, height: height)
		} else {
			throw GeoTIFFError.unsupportedBandCount(Int32(samplesPerPixel))
		}
	}

	
	// MARK: - Image Creation
	
	private static func createPalettedImage(samples: [NSNumber], width: Int, height: Int, colorMap: Data, isLittleEndian: Bool, transparentIndex: Int? = 0) throws -> (Data, UIImage?) {
		let colorMapEntries = colorMap.count / 6
		var rgbaData = Data(count: width * height * 4)
		
		rgbaData.withUnsafeMutableBytes { rgbaPtr in
			let rgba = rgbaPtr.bindMemory(to: UInt8.self).baseAddress!
			for i in 0..<(width * height) {
				let idx = Int(truncating: samples[i])
				
				// Check if this is the transparent index
				if let transparentIdx = transparentIndex, idx == transparentIdx {
					rgba[i * 4] = 0      // R
					rgba[i * 4 + 1] = 0  // G
					rgba[i * 4 + 2] = 0  // B
					rgba[i * 4 + 3] = 0  // A - fully transparent
					continue
				}
				
				if idx < colorMapEntries {
					let rOffset = idx * 2
					let gOffset = colorMapEntries * 2 + idx * 2
					let bOffset = colorMapEntries * 4 + idx * 2
					
					let r = readUInt16(from: colorMap, offset: rOffset, littleEndian: isLittleEndian)
					let g = readUInt16(from: colorMap, offset: gOffset, littleEndian: isLittleEndian)
					let b = readUInt16(from: colorMap, offset: bOffset, littleEndian: isLittleEndian)
					
					rgba[i * 4] = UInt8(r >> 8)
					rgba[i * 4 + 1] = UInt8(g >> 8)
					rgba[i * 4 + 2] = UInt8(b >> 8)
					rgba[i * 4 + 3] = 255  // A - fully opaque
				} else {
					rgba[i * 4] = 0
					rgba[i * 4 + 1] = 0
					rgba[i * 4 + 2] = 0
					rgba[i * 4 + 3] = 0    // A - fully transparent for out-of-bounds indices
				}
			}
		}
		
		let image = createUIImage(from: rgbaData, width: width, height: height, isRGBA: true)
		return (rgbaData, image)
	}
	
	private static func createGrayscaleImage(samples: [NSNumber], width: Int, height: Int) throws -> (Data, UIImage?) {
		// Convert grayscale to RGBA with transparency support
		var rgbaData = Data(count: width * height * 4)
		
		rgbaData.withUnsafeMutableBytes { ptr in
			let rgba = ptr.bindMemory(to: UInt8.self).baseAddress!
			for i in 0..<(width * height) {
				let grayValue = UInt8(truncating: samples[i])
				
				// Make white pixels (value 255) transparent, others semi-transparent based on intensity
				if grayValue == 255 {
					// Full transparency for white
					rgba[i * 4] = 0      // R
					rgba[i * 4 + 1] = 0  // G
					rgba[i * 4 + 2] = 0  // B
					rgba[i * 4 + 3] = 0  // A - fully transparent
				} else if grayValue == 0 {
					// Full opacity for black
					rgba[i * 4] = 0      // R
					rgba[i * 4 + 1] = 0  // G
					rgba[i * 4 + 2] = 0  // B
					rgba[i * 4 + 3] = 255  // A - fully opaque
				} else {
					// For other grayscale values, use the grayscale value
					rgba[i * 4] = grayValue     // R
					rgba[i * 4 + 1] = grayValue // G
					rgba[i * 4 + 2] = grayValue // B
					rgba[i * 4 + 3] = 255       // A - fully opaque
				}
			}
		}
		
		let image = createUIImage(from: rgbaData, width: width, height: height, isRGBA: true)
		return (rgbaData, image)
	}
	
	private static func createRGBImage(samples: [NSNumber], width: Int, height: Int) throws -> (Data, UIImage?) {
		var rgbaData = Data(count: width * height * 4)
		rgbaData.withUnsafeMutableBytes { ptr in
			let rgba = ptr.bindMemory(to: UInt8.self).baseAddress!
			for i in 0..<(width * height) {
				let r = UInt8(truncating: samples[i*3])
				let g = UInt8(truncating: samples[i*3 + 1])
				let b = UInt8(truncating: samples[i*3 + 2])
				
				// Make white pixels transparent, others opaque
				if r == 255 && g == 255 && b == 255 {
					rgba[i * 4] = 0      // R
					rgba[i * 4 + 1] = 0  // G
					rgba[i * 4 + 2] = 0  // B
					rgba[i * 4 + 3] = 0  // A - fully transparent
				} else {
					rgba[i * 4] = r
					rgba[i * 4 + 1] = g
					rgba[i * 4 + 2] = b
					rgba[i * 4 + 3] = 255  // A - fully opaque
				}
			}
		}
		let image = createUIImage(from: rgbaData, width: width, height: height, isRGBA: true)
		return (rgbaData, image)
	}
	
	private static func createUIImage(from data: Data, width: Int, height: Int, isRGBA: Bool) -> UIImage? {
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
		let bytesPerPixel = 4
		
		guard let provider = CGDataProvider(data: data as CFData),
			  let cgImage = CGImage(
				width: width,
				height: height,
				bitsPerComponent: 8,
				bitsPerPixel: bytesPerPixel * 8,
				bytesPerRow: width * bytesPerPixel,
				space: colorSpace,
				bitmapInfo: bitmapInfo,
				provider: provider,
				decode: nil,
				shouldInterpolate: true,
				intent: .defaultIntent
			  ) else {
			return nil
		}
		
		// Verify the image has alpha channel
		let alphaInfo = cgImage.alphaInfo
		print("Created image with alpha info: \(alphaInfo.rawValue)")
		
		return UIImage(cgImage: cgImage)
	}
	
	// MARK: - Helpers
	
	private static func readUInt16(from data: Data, offset: Int, littleEndian: Bool) -> UInt16 {
		guard offset + 2 <= data.count else { return 0 }
		let value: UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) }
		return littleEndian ? value.littleEndian : value.bigEndian
	}
	
	private static func readDoubles(tagValue: Any, expectedCount: Int) -> [Double]? {
		if let arr = tagValue as? [Double], arr.count >= expectedCount {
			return Array(arr.prefix(expectedCount))
		} else if let arr = tagValue as? [Any], arr.count >= expectedCount {
			// Attempt to convert each element to Double
			var result: [Double] = []
			for v in arr.prefix(expectedCount) {
				if let d = v as? Double { result.append(d) }
				else if let i = v as? Int { result.append(Double(i)) }
				else if let n = v as? NSNumber { result.append(n.doubleValue) }
				else { return nil }
			}
			return result
		} else if let n = tagValue as? NSNumber {
			return [n.doubleValue]
		}
		return nil
	}

	
	private static func calculateBounds(geoTransform: [Double], width: Int, height: Int) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
		let originX = geoTransform[0]
		let originY = geoTransform[3]
		let pixelWidth = geoTransform[1]
		let pixelHeight = geoTransform[5]
		
		let minLon = originX
		let maxLon = originX + Double(width)*pixelWidth
		let maxLat = originY
		let minLat = originY + Double(height)*pixelHeight
		
		return (
			minLat: min(minLat, maxLat),
			maxLat: max(minLat, maxLat),
			minLon: min(minLon, maxLon),
			maxLon: max(minLon, maxLon)
		)
	}
	
	// MARK: - TIFF Tag Parsing
	
	private static func parseTIFFTags(from data: Data) throws -> [UInt16: Any] {
		guard data.count >= 8 else { throw GeoTIFFError.invalidTIFF }
		var tags: [UInt16: Any] = [:]
		
		// Byte order
		let byteOrderMarker: UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }
		let isLittleEndian = (byteOrderMarker == 0x4949)
		
		// IFD offset
		let ifdOffset: UInt32 = data.withUnsafeBytes { ptr in
			let val = ptr.load(fromByteOffset: 4, as: UInt32.self)
			return isLittleEndian ? val.littleEndian : val.bigEndian
		}
		
		guard Int(ifdOffset)+2 <= data.count else { throw GeoTIFFError.invalidTIFF }
		let numEntries: UInt16 = data.withUnsafeBytes { ptr in
			let val = ptr.load(fromByteOffset: Int(ifdOffset), as: UInt16.self)
			return isLittleEndian ? val.littleEndian : val.bigEndian
		}
		
		var offset = Int(ifdOffset)+2
		for _ in 0..<numEntries {
			guard offset + 12 <= data.count else { break }
			let entryData = data.subdata(in: offset..<(offset+12))
			if let (tag, value) = parseIFDEntry(entryData, data: data, isLittleEndian: isLittleEndian) {
				tags[tag] = value
				print("Parsed tag \(tag): \(value)")
			}
			offset += 12
		}
		
		return tags
	}
	
	private static func parseIFDEntry(_ entryData: Data, data: Data, isLittleEndian: Bool) -> (UInt16, Any)? {
		guard entryData.count >= 12 else { return nil }
		
		let tag: UInt16 = entryData.withUnsafeBytes { ptr in
			let val = ptr.load(fromByteOffset: 0, as: UInt16.self)
			return isLittleEndian ? val.littleEndian : val.bigEndian
		}
		
		let fieldType: UInt16 = entryData.withUnsafeBytes { ptr in
			let val = ptr.load(fromByteOffset: 2, as: UInt16.self)
			return isLittleEndian ? val.littleEndian : val.bigEndian
		}
		
		let count: UInt32 = entryData.withUnsafeBytes { ptr in
			let val = ptr.load(fromByteOffset: 4, as: UInt32.self)
			return isLittleEndian ? val.littleEndian : val.bigEndian
		}
		
		let valueOffset: UInt32 = entryData.withUnsafeBytes { ptr in
			let val = ptr.load(fromByteOffset: 8, as: UInt32.self)
			return isLittleEndian ? val.littleEndian : val.bigEndian
		}
		
		let value: Any?
		switch fieldType {
		case 3: // SHORT
			if count == 1 {
				value = Int(valueOffset & 0xFFFF)
			} else {
				value = parseShortArray(from: data, offset: Int(valueOffset), count: Int(count), littleEndian: isLittleEndian)
			}
		case 4: // LONG
			if count == 1 {
				value = Int(valueOffset)
			} else {
				value = parseLongArray(from: data, offset: Int(valueOffset), count: Int(count), littleEndian: isLittleEndian)
			}
		case 12: // DOUBLE
			value = parseDoubleArray(from: data, offset: Int(valueOffset), count: Int(count), littleEndian: isLittleEndian)
		case 2: // ASCII
			value = parseString(from: data, offset: Int(valueOffset), count: Int(count))
		case 1: // BYTE
			value = parseByteArray(from: data, offset: Int(valueOffset), count: Int(count))
		default:
			value = nil
		}
		
		if let v = value { return (tag, v) }
		return nil
	}
	
	private static func parseDoubleArray(from data: Data, offset: Int, count: Int, littleEndian: Bool) -> [Double]? {
		guard offset + count * 8 <= data.count else { return nil }
		var result: [Double] = []
		for i in 0..<count {
			let byteOffset = offset + i * 8
			let slice = data.subdata(in: byteOffset..<byteOffset + 8)
			let val = slice.withUnsafeBytes { $0.load(as: UInt64.self) }
			result.append(Double(bitPattern: littleEndian ? val.littleEndian : val.bigEndian))
		}
		return result
	}
	
	private static func parseShortArray(from data: Data, offset: Int, count: Int, littleEndian: Bool) -> [Int]? {
		guard offset + count * 2 <= data.count else { return nil }
		var result: [Int] = []
		for i in 0..<count {
			let byteOffset = offset + i * 2
			let slice = data.subdata(in: byteOffset..<byteOffset + 2)
			let val = slice.withUnsafeBytes { $0.load(as: UInt16.self) }
			result.append(Int(littleEndian ? val.littleEndian : val.bigEndian))
		}
		return result
	}

	private static func parseLongArray(from data: Data, offset: Int, count: Int, littleEndian: Bool) -> [Int]? {
		guard offset + count * 4 <= data.count else { return nil }
		var result: [Int] = []
		for i in 0..<count {
			let byteOffset = offset + i * 4
			let slice = data.subdata(in: byteOffset..<byteOffset + 4)
			let val = slice.withUnsafeBytes { $0.load(as: UInt32.self) }
			result.append(Int(littleEndian ? val.littleEndian : val.bigEndian))
		}
		return result
	}
	
	private static func parseByteArray(from data: Data, offset: Int, count: Int) -> Data? {
		guard offset+count <= data.count else { return nil }
		return data.subdata(in: offset..<offset+count)
	}
	
	private static func parseString(from data: Data, offset: Int, count: Int) -> String? {
		guard offset+count <= data.count else { return nil }
		return String(data: data.subdata(in: offset..<offset+count), encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
	}
}
