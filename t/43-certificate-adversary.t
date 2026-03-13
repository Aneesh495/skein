use strict;
use warnings;
use Test::More;
use Skein::Model;
use Skein::Engine;
use Skein::Certificate;
use Skein::Util qw(deep_copy digest);

my $model=Skein::Model->from_text(<<'MODEL');
noise a ~ 0;
noise b ~ 1/3;
noise c ~ 1;
node x = a ^ b;
node y = x | c;
query q = P(x) given(y);
query cf = P(x) factual(x) do(x=0);
MODEL
my $engine=Skein::Engine->new($model);
my $certificate=Skein::Certificate->create($engine,'q');
is(Skein::Certificate->verify($model,$certificate)->{probability},'1/3','trusted base certificate');
my @mutations=(
    ['changed model identity',sub { $_[0]{model_digest}='0' x 64 }],
    ['changed prior',sub { $_[0]{priors}{a}='1/2' }],
    ['unknown certificate schema',sub { $_[0]{schema}='future' }],
    ['null schema',sub { $_[0]{schema}=undef }],
    ['unknown payload field',sub { $_[0]{invented}=1 }],
    ['changed query outcome',sub { $_[0]{query}{event}={op=>'var',name=>'y'} }],
    ['invalid intervention',sub { $_[0]{query}{interventions}={a=>0} }],
    ['unknown expression variable',sub { $_[0]{query}{event}={op=>'var',name=>'missing'} }],
    ['incorrect probability',sub { $_[0]{result}{probability}='1/2' }],
    ['incorrect joint mass',sub { $_[0]{result}{numerator}='0' }],
    ['incorrect evidence mass',sub { $_[0]{result}{denominator}='0' }],
    ['nonfinite result',sub { $_[0]{result}{probability}='NaN' }],
    ['extra result field',sub { $_[0]{result}{invented}=1 }],
    ['swapped roots',sub { @{$_[0]{diagram}{roots}}=reverse @{$_[0]{diagram}{roots}} }],
    ['constant forged numerator',sub { $_[0]{diagram}{roots}[0]=0 }],
    ['missing root',sub { pop @{$_[0]{diagram}{roots}} }],
    ['additional root',sub { push @{$_[0]{diagram}{roots}},1 }],
    ['changed rank variable',sub { $_[0]{diagram}{variables}=[reverse @{$_[0]{diagram}{variables}}] }],
    ['duplicate variable',sub { $_[0]{diagram}{variables}[0]=$_[0]{diagram}{variables}[1] }],
    ['forward child edge',sub { $_[0]{diagram}{nodes}[0]{high}=2 }],
    ['out of range rank',sub { $_[0]{diagram}{nodes}[0]{rank}=100 }],
    ['unreduced decision',sub { $_[0]{diagram}{nodes}[0]{high}=$_[0]{diagram}{nodes}[0]{low} }],
    ['wrong node identity',sub { $_[0]{diagram}{nodes}[0]{id}=99 }],
    ['unknown diagram schema',sub { $_[0]{diagram}{schema}='future' }],
    ['nonarray node table',sub { $_[0]{diagram}{nodes}={} }],
    ['changed world claim',sub { $_[0]{verification}{worlds}=7 }],
    ['changed variable claim',sub { $_[0]{verification}{variables}=2 }],
    ['null variable claim',sub { $_[0]{verification}{variables}=undef }],
    ['nonnumeric world claim',sub { $_[0]{verification}{worlds}='lots' }],
    ['unknown proof method',sub { $_[0]{verification}{method}='trust me' }],
);
for my $case (@mutations) {
    my $changed=deep_copy($certificate);
    $case->[1]->($changed->{payload});
    $changed->{sha256}=digest($changed->{payload});
    my @warnings;
    local $SIG{__WARN__}=sub { push @warnings,$_[0] };
    my $ok=eval { Skein::Certificate->verify($model,$changed); 1 };
    ok(!$ok,"rehashed $case->[0] refused");
    ok(length($@)>0,"$case->[0] diagnostic");
    is_deeply(\@warnings,[],"$case->[0] does not leak a runtime warning");
}
for my $hash (undef,[],{},'0','z'x64) {
    my $changed=deep_copy($certificate);
    $changed->{sha256}=$hash;
    my @warnings;
    local $SIG{__WARN__}=sub { push @warnings,$_[0] };
    ok(!eval { Skein::Certificate->verify($model,$changed); 1 },'invalid envelope hash refused');
    is_deeply(\@warnings,[],'invalid hash has a clean diagnostic');
}
my $equivalent=deep_copy($certificate);
$equivalent->{payload}{result}{probability}='2/6';
$equivalent->{sha256}=digest($equivalent->{payload});
ok(Skein::Certificate->verify($model,$equivalent)->{verified},'equivalent exact rational spelling accepted');
my $cf=Skein::Certificate->create($engine,'cf');
is(Skein::Certificate->verify($model,$cf)->{probability},'0','counterfactual zero result remains valid');
my $zero_prior=Skein::Model->from_text('noise u ~ 0; node x = u; query q = P(x);');
my $forged=Skein::Certificate->create(Skein::Engine->new($zero_prior),'q');
$forged->{payload}{diagram}{roots}[0]=0;
$forged->{sha256}=digest($forged->{payload});
ok(!eval { Skein::Certificate->verify($zero_prior,$forged); 1 },'same numeric mass cannot hide a false zero-weight truth function');
done_testing;
