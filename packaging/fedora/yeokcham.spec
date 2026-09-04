Name:           yeokcham
Version:        %{version}
Release:        %{build_release}%{?dist}
Summary:        Experimental model-first local-first VCS development client
License:        MIT
BuildArch:       x86_64
Source0:         yeokcham
Source1:         LICENSE

%description
Development-only Yeokcham V4 client. It installs no service and has no RPM
scriptlets; every VCS action remains an explicit user command.

%prep

%build

%install
install -Dpm 0755 %{SOURCE0} %{buildroot}%{_bindir}/yeokcham
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%license %{_licensedir}/%{name}/LICENSE
%{_bindir}/yeokcham
