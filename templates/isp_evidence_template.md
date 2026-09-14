# BẰNG CHỨNG KỸ THUẬT ĐỂ BÁO CÁO NHÀ MẠNG (ISP)

_Địa điểm: [ĐIỀN ĐỊA ĐIỂM] — Ngày: [ĐIỀN NGÀY]_

## Tóm tắt vấn đề
[Mô tả ngắn gọn: speedtest nhanh nhưng duyệt web chậm / mất gói tin / độ trễ cao...]

## Bằng chứng cụ thể (từ script diagnose.ps1)

### 1. Tốc độ khi chỉ dùng 1 kết nối (1 luồng TCP)
- [ĐIỀN kết quả mục "Single-stream speed" trong report]

### 2. Tốc độ khi dùng 4 kết nối song song
- [ĐIỀN "Per-stream speeds" và "Aggregate 4-stream speed"]
- [ĐIỀN "Scaling factor" — gần 4x nghĩa là bị giới hạn theo từng kết nối]

### 3. Speedtest (nhiều kết nối song song)
- Download: [ ] Mbps | Upload: [ ] Mbps | Ping: [ ] ms

### 4. Độ trễ & mất gói (mục 1 và 4 trong report)
- Gateway: [ ] ms trung bình, mất gói: [ ]/10
- Internet: [ ] ms trung bình, mất gói: [ ]/15

### 5. Traceroute — điểm nghẽn (nếu có, mục 5 trong report)
- [ĐIỀN hop nào tăng đột biến độ trễ]

### 6. Các yếu tố đã loại trừ phía thiết bị
- Tín hiệu Wi-Fi: [ ]%, không có phần mềm bảo mật/proxy/VPN can thiệp
- DNS: đã kiểm tra/tối ưu
- [Điền thêm nếu có]

## Yêu cầu cụ thể với tổng đài ISP
1. Hỏi rõ: gói cước hiện tại có đang áp dụng **giới hạn tốc độ theo từng kết nối
   (per-connection/per-session throttling hoặc "fair usage policy")** hay không?
2. Nếu có, yêu cầu gỡ bỏ giới hạn này hoặc nâng cấp gói không áp dụng chính sách đó.
3. Nếu nhà mạng nói không có giới hạn per-connection, yêu cầu kỹ thuật viên kiểm tra
   lại cấu hình QoS/traffic shaping trên đường truyền.

## Câu mở đầu gợi ý khi gọi điện
"Chào anh/chị, mạng nhà em tốc độ đo bằng speedtest thì rất cao ([ ]Mbps) nhưng khi
duyệt web thực tế thì rất chậm. Em đã tự kiểm tra và phát hiện tốc độ bị giới hạn theo
từng kết nối (mỗi kết nối chỉ đạt khoảng [ ]Mbps dù tổng băng thông thực tế cao hơn
nhiều), nghi ngờ có chính sách giới hạn per-connection/fair usage đang áp dụng trên
đường truyền. Anh/chị có thể kiểm tra giúp em không ạ?"
