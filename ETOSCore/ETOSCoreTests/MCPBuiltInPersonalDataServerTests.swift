// ============================================================================
// MCPBuiltInPersonalDataServerTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证内建个人数据 MCP Server 的配置、发现与无权限工具调用链路。
// ============================================================================

import Foundation
#if canImport(HealthKit)
import HealthKit
#endif
import Testing
@testable import ETOSCore

@Suite("内建 MCP 个人数据服务器测试")
struct MCPBuiltInPersonalDataServerTests {
    #if canImport(HealthKit)
    @Test("血压写入样本将收缩压和舒张压组成同一条记录")
    func testBloodPressureSampleBuilder() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = MCPBuiltInBloodPressureSampleBuilder.make(
            systolic: 128,
            diastolic: 82,
            heartRate: 70,
            startDate: date,
            endDate: date,
            correlationMetadata: ["ETOSNote": "晨间测量"],
            heartRateMetadata: nil
        )
        let systolicType = HKQuantityType(.bloodPressureSystolic)
        let diastolicType = HKQuantityType(.bloodPressureDiastolic)
        let systolicSample = try #require(
            samples.correlation.objects(for: systolicType).first as? HKQuantitySample
        )
        let diastolicSample = try #require(
            samples.correlation.objects(for: diastolicType).first as? HKQuantitySample
        )

        #expect(samples.correlation.correlationType == HKCorrelationType(.bloodPressure))
        #expect(systolicSample.quantity.doubleValue(for: .millimeterOfMercury()) == 128)
        #expect(diastolicSample.quantity.doubleValue(for: .millimeterOfMercury()) == 82)
        #expect(samples.heartRate?.quantity.doubleValue(
            for: HKUnit.count().unitDivided(by: .minute())
        ) == 70)
        #expect(samples.correlation.metadata?["ETOSNote"] as? String == "晨间测量")
        #expect(samples.shareTypes.count == 4)
        #expect(samples.objectsToSave.count == 2)
    }
    #endif
}
