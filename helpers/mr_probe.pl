# /usr/bin/perl(번들 id com.apple.perl5 — MediaRemote 읽기 게이트 통과)이 특권 컨텍스트에서
# mr_probe.dylib을 로드해 adapter_probe()를 호출한다. 결과는 dylib이 stdout에 출력한다.
# 실패는 모두 "?"(불명)로 떨어뜨려 호출측이 "재개 안 함"으로 안전 처리하게 한다.
#
# 사용: /usr/bin/perl mr_probe.pl <mr_probe.dylib 절대경로>
use DynaLoader;

my $dylib = $ARGV[0] or do { print "?\n"; exit 0 };
my $libref = DynaLoader::dl_load_file($dylib, 0) or do { print "?\n"; exit 0 };
my $sym = DynaLoader::dl_find_symbol($libref, "adapter_probe") or do { print "?\n"; exit 0 };
# void(void) C 함수를 perl 호출가능 sub로 설치한다(추가 인자는 함수가 무시).
DynaLoader::dl_install_xsub("adapter_probe", $sym);
adapter_probe();
