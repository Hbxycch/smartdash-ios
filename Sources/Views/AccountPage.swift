import Foundation
import SwiftUI

/// 用户账号页：注册 / 登录（与 Android AccountActivity 同口径）。
///
/// 归属模型：激活码与用户绑定、数据与设备绑定、登录只决定可见性；
/// 一台车机只能属于一个账号，本机被别人占用时不能凭本账号密码抢占。
struct AccountPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss

    @State private var registerMode = true
    @State private var username = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var vehicle = ""
    @State private var loginPwd = ""

    @State private var message = ""
    @State private var messageIsError = false
    @State private var busy = false
    @State private var policy: [String: Any]?
    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                if settings.isUserLoggedIn {
                    sessionSection
                } else {
                    modeSection
                    if registerMode { registerSection } else { loginSection }
                    submitSection
                }
                hintSection
            }
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { loadPolicy(); refreshMe() }
            .alert("退出登录", isPresented: $showLogoutConfirm) {
                Button("退出", role: .destructive) { logout() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("退出后本机数据仍保留在设备上，只是不再与账号关联。确认退出？")
            }
        }
    }

    // MARK: - 已登录

    private var sessionSection: some View {
        Section {
            HStack {
                Text("当前用户")
                Spacer()
                Text(settings.userName.isEmpty ? "--" : settings.userName)
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("试用期")
                Spacer()
                Text(settings.userTrialDays > 0 ? "剩 \(settings.userTrialDays) 天" : "已结束")
                    .foregroundColor(settings.userTrialDays > 0 ? .secondary : .orange)
                    .monospacedDigit()
            }
            HStack {
                Text("本机车辆")
                Spacer()
                Text(settings.boundVehicle.isEmpty ? "未绑定（去设置 → 云同步激活）" : settings.boundVehicle)
                    .foregroundColor(.secondary)
                    .font(settings.boundVehicle.isEmpty ? .callout : .body)
            }
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                Label("退出登录", systemImage: "tray.and.arrow.down")
            }
        } footer: {
            Text("激活码在「设置 → 云同步」里填写并激活，激活后本机就挂在你的账号下，可在同一账号下添加多辆车。")
        }
    }

    // MARK: - 注册 / 登录切换

    private var modeSection: some View {
        Section {
            Picker("", selection: $registerMode) {
                Text("注册").tag(true)
                Text("登录").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: registerMode) { _ in
                message = ""
                loginPwd = password          // 注册页填过的密码带到登录页，少打一次
            }
        }
    }

    private var registerSection: some View {
        Section("注册信息") {
            TextField("用户名（必填，字母/数字/下划线）", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码（必填）", text: $password)
            SecureField("确认密码（再输入一次）", text: $password2)
            TextField("手机号（必填，用于找回密码）", text: $phone)
                .keyboardType(.phonePad)
            TextField("邮箱（选填，用于接收报表与告警）", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("车型（选填，如 九号 MZ MIX）", text: $vehicle)
        }
    }

    private var loginSection: some View {
        Section("登录") {
            TextField("用户名", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码", text: $loginPwd)
        }
    }

    private var submitSection: some View {
        Section {
            Button {
                submit()
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().padding(.trailing, 6) }
                    Text(registerMode ? "创建账号" : "登录")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(busy || !canSubmit)
        } footer: {
            Text(message.isEmpty ? hintText : message)
                .foregroundColor(messageIsError ? .red : .secondary)
        }
    }

    private var hintSection: some View {
        Section {
            Text("激活码与用户绑定，数据与设备绑定：换新车或重装 App，登录同一账号就能认回这辆车的历史数据。新注册账号自动获得 7 天免费试用。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 校验

    private var canSubmit: Bool {
        let user = registerMode ? username : username
        let pwd = registerMode ? password : loginPwd
        return user.trimmingCharacters(in: .whitespaces).count >= 2 && pwd.count >= 6
    }

    /// 密码规则：服务端可配置（长度/大小写/数字/符号），取不到用默认
    private func checkPolicy(_ pwd: String) -> String? {
        let minLen = policy?["minLength"] as? Int ?? 8
        if pwd.count < minLen { return "密码至少 \(minLen) 位" }
        if pwd != pwd.trimmingCharacters(in: .whitespaces) { return "密码首尾不能有空格" }
        let reqUpper = policy?["requireUpper"] as? Bool ?? true
        let reqLower = policy?["requireLower"] as? Bool ?? true
        let reqDigit = policy?["requireDigit"] as? Bool ?? true
        let reqSymbol = policy?["requireSymbol"] as? Bool ?? false
        if reqUpper && pwd.range(of: "[A-Z]", options: .regularExpression) == nil { return "密码需要包含大写字母" }
        if reqLower && pwd.range(of: "[a-z]", options: .regularExpression) == nil { return "密码需要包含小写字母" }
        if reqDigit && pwd.range(of: "[0-9]", options: .regularExpression) == nil { return "密码需要包含数字" }
        if reqSymbol && pwd.range(of: "[!@#$%^&*()\\-_=+\\[\\]{};:,.?/|~]", options: .regularExpression) == nil { return "密码需要包含符号" }
        return nil
    }

    private func showMsg(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    private func loadPolicy() {
        let base = cloud.normalizedBaseURL
        guard !base.isEmpty else { return }
        Task {
            do {
                policy = try await AccountApi.passwordPolicy(base: base)
            } catch {
                // 取不到就用默认规则，不打扰用户
            }
        }
    }

    /// 进页面拉一次最新账号态（与 Android AccountActivity.refreshMe 同口径）：
    /// 试用天数、本机绑定车辆名。激活完从设置页回来能立刻变对；
    /// 已激活的设备再进来也能同步到最新归属。失败沿用本地缓存。
    private func refreshMe() {
        let base = cloud.normalizedBaseURL
        guard settings.isUserLoggedIn, !base.isEmpty else { return }
        let no = cloud.deviceNo
        Task {
            do {
                let me = try await AccountApi.me(base: base, token: settings.userToken, deviceNo: no)
                await MainActor.run {
                    if let u = me["user"] as? [String: Any],
                       let trial = u["trialDaysLeft"] as? Int, trial >= 0 {
                        settings.userTrialDays = trial
                    }
                    var boundName = ""
                    if let dev = me["device"] as? [String: Any], dev["bound"] as? Bool == true,
                       let v = dev["vehicle"] as? [String: Any],
                       let model = v["model"] as? String {
                        boundName = model
                    }
                    settings.boundVehicle = boundName
                }
            } catch {
                // 网络失败就沿用本地缓存
            }
        }
    }

    private var hintText: String {
        let minLen = policy?["minLength"] as? Int ?? 8
        let maxLen = policy?["maxLength"] as? Int ?? 32
        var rules = "密码规则：\(minLen)-\(maxLen) 位"
        if policy?["requireUpper"] as? Bool ?? true { rules += " · 含大写" }
        if policy?["requireLower"] as? Bool ?? true { rules += " · 含小写" }
        if policy?["requireDigit"] as? Bool ?? true { rules += " · 含数字" }
        if policy?["requireSymbol"] as? Bool == true { rules += " · 含符号" }
        return rules
    }

    // MARK: - 提交

    private func submit() {
        guard !busy else { return }
        let base = cloud.normalizedBaseURL
        guard !base.isEmpty else {
            showMsg("请先到「设置 → 云同步」填写服务器地址", isError: true)
            return
        }

        let user = username.trimmingCharacters(in: .whitespaces)
        let pwd = registerMode ? password : loginPwd
        guard user.count >= 2 else { showMsg("用户名至少 2 位", isError: true); return }
        guard pwd.count >= 6 else { showMsg("密码至少 6 位", isError: true); return }

        let regPhone: String
        if registerMode {
            let p = phone.trimmingCharacters(in: .whitespaces)
            guard pwd == password2 else { showMsg("两次输入的密码不一致", isError: true); return }
            guard !p.isEmpty else { showMsg("请填写手机号（用于找回密码）", isError: true); return }
            guard p.range(of: "^1[3-9]\\d{9}$", options: .regularExpression) != nil else {
                showMsg("手机号格式不正确（11 位，1 开头）", isError: true); return
            }
            if let err = checkPolicy(pwd) { showMsg(err, isError: true); return }
            regPhone = p
        } else {
            regPhone = ""
        }

        busy = true
        message = ""
        let deviceNo = cloud.deviceNo
        let fp = AccountApi.fingerprint()
        let vehicleModel = vehicle.trimmingCharacters(in: .whitespaces)
        let emailText = email.trimmingCharacters(in: .whitespaces)

        Task {
            do {
                let r = registerMode
                    ? try await AccountApi.register(base: base, username: user, password: pwd,
                                                    phone: regPhone, email: emailText,
                                                    vehicleModel: vehicleModel,
                                                    deviceNo: deviceNo, deviceFp: fp)
                    : try await AccountApi.login(base: base, username: user, password: pwd,
                                                 deviceNo: deviceNo)
                await MainActor.run { applySession(r, registered: registerMode, fallbackName: user) }
            } catch let e as AccountApi.ApiError {
                await MainActor.run {
                    busy = false
                    showMsg(AccountApi.ApiError.friendly(e), isError: true)
                }
            } catch {
                await MainActor.run {
                    busy = false
                    showMsg("无法连接服务器：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    /// 落会话：token、用户名、试用天数、车型、绑定车辆三态
    private func applySession(_ r: [String: Any], registered: Bool, fallbackName: String) {
        settings.userToken = r["token"] as? String ?? ""
        if let u = r["user"] as? [String: Any] {
            settings.userName = u["username"] as? String ?? fallbackName
            settings.userTrialDays = u["trialDaysLeft"] as? Int ?? 0
            if let model = u["vehicleModel"] as? String, !model.isEmpty {
                settings.deviceModelHint = model
            }
        } else {
            settings.userName = fallbackName
        }

        // 本机归属三态：bound=属于本账号 / blocked=属于别人（服务端已拒绝）/ 其他=未绑定
        var boundName = ""
        if let dev = r["device"] as? [String: Any] {
            if dev["bound"] as? Bool == true,
               let v = dev["vehicle"] as? [String: Any],
               let model = v["model"] as? String {
                boundName = model
            }
        }
        settings.boundVehicle = boundName
        busy = false

        let trial = settings.userTrialDays
        if registered, trial > 0 {
            showMsg("注册成功，已自动登录，试用 \(trial) 天。激活码在「设置 → 云同步」里绑定本机。", isError: false)
        } else {
            showMsg(boundName.isEmpty
                    ? "登录成功，本机还没有绑定车辆。下一步去「设置 → 云同步」用激活码绑定。"
                    : "登录成功，本机已绑定：\(boundName)", isError: false)
        }
    }

    private func logout() {
        settings.userToken = ""
        settings.userName = ""
        settings.userTrialDays = 0
        settings.boundVehicle = ""
        message = ""
        registerMode = false
    }
}
