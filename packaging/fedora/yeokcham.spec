Name:           yeokcham
Version:        %{?version}%{!?version:0.0.0}
Release:        %{?build_release}%{!?build_release:0.dev}
Summary:        Signed semantic change control for repositories
License:        MIT
URL:            https://github.com/gongahkia/yeokcham
Source0:        yeokcham
Source1:        LICENSE
BuildArch:      x86_64

%description
Yeokcham is a signed semantic change control tool for repositories.

%prep

%build

%install
install -D -m 0755 %{SOURCE0} %{buildroot}/usr/bin/yeokcham
install -D -m 0644 %{SOURCE1} %{buildroot}%{_datadir}/licenses/%{name}/LICENSE

%files
/usr/bin/yeokcham
%license %{_datadir}/licenses/%{name}/LICENSE

%changelog
* Mon Sep 21 2026 Yeokcham Contributors <opensource@yeokcham.invalid> - %{version}-%{release}
- Development packaging spec for CI artifact smoke tests
