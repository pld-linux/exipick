#
%include        /usr/lib/rpm/macros.perl
Summary:	Tool that displays messages from Exim queue
Summary(pl.UTF-8):	Narzędzie do wyświetlania wiadomości z kolejki Exima
Name:		exipick
Version:	20100323.0
Release:	2
License:	GPL v2+
Group:		Applications
Source0:	http://jetmore.org/john/code/%{name}.%{version}
# Source0-md5:	3b1b1d0ae0f08278115db6aa863798eb
URL:		http://jetmore.org/john/code/#exipick
BuildRequires:	perl-tools-pod
BuildRequires:	rpm-perlprov
Suggests:	perl-perldoc
BuildArch:	noarch
BuildRoot:	%{tmpdir}/%{name}-%{version}-root-%(id -u -n)

%description
Tool that displays messages from Exim queue based on a variety of
criteria.

%description -l pl.UTF-8
Narzędzie które pozwala wyświetlać wiadomości z koleki Exima na
podstawie różnych kryteriów.

%prep
%setup -q -c -T
sed -e "s#/local/exim/spool#/var/spool/exim#g" %{SOURCE0} > %{name}.pl || exit 1

%build
pod2man %{SOURCE0} > %{name}.1
pod2text %{SOURCE0} > %{name}.txt

%install
rm -rf $RPM_BUILD_ROOT
install -d $RPM_BUILD_ROOT{%{_bindir},%{_mandir}/man1}

install %{name}.pl $RPM_BUILD_ROOT%{_bindir}/%{name}
install %{name}.1 $RPM_BUILD_ROOT%{_mandir}/man1/%{name}.1

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(644,root,root,755)
%attr(755,root,root) %{_bindir}/%{name}
%{_mandir}/man1/%{name}.1*
%doc %{name}.txt
