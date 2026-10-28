import CryptoKit
import Foundation

/// 登记相关的两个特征值（docs/protocol.md「登记确认」「手机请求显示登记码」），和 Windows、App 一致。
public enum EnrollProtocol {
    /// 登记确认：手机保存登记后写一条用新密钥签名的确认，登记窗口收到就关。只用来关窗口，不算在场、不能解锁
    public static let ackUUID = "be282b23-6b55-4b86-86ea-b7f8f3c273e3"
    /// 手机请求显示登记码：电脑上先确认再弹出二维码。有没有登记都开放
    public static let requestUUID = "3465d7ce-93d4-4d36-9c16-0619b8ebadbf"
    public static let ackLength = 20
    public static let requestPayload = Data([0x01])

    /// 确认里的 keyID；长度不对返回 nil
    public static func ackKeyID(_ data: Data) -> UInt32? {
        guard data.count == ackLength else { return nil }
        let b = [UInt8](data)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    /// keyID（小端）+ HMAC-SHA256(secret, "enroll-ack-v1" ‖ reportNonce ‖ keyID 小端) 的前 16 字节
    public static func ack(key: UnlockKey, reportNonce: Data) -> Data {
        var id = Data()
        withUnsafeBytes(of: key.id.littleEndian) { id.append(contentsOf: $0) }
        var message = Data("enroll-ack-v1".utf8)
        message.append(reportNonce)
        message.append(id)
        let tag = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key.secret))
        return id + Data(tag.prefix(16))
    }

    public static func verifyAck(_ data: Data, key: UnlockKey, reportNonce: Data) -> Bool {
        guard data.count == ackLength, key.secret.count == 32, reportNonce.count == 16 else { return false }
        let expected = ack(key: key, reportNonce: reportNonce)
        return zip(expected, data).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// 请求显示登记码的 ATT 应用错误值
public enum EnrollRequestStatus: UInt8 {
    /// 电脑锁着屏，锁屏界面上看不到窗口
    case locked = 0x81
    /// 电脑弹不出窗口
    case unavailable = 0x82
}
