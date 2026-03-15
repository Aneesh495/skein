use strict;
use warnings;
use Test::More;
use Skein::Model;
use Skein::Engine;
use Skein::Eliminate;
use Skein::Mission;
use Skein::Compare;
use Skein::Expr qw(var);
use Skein::Util qw(deep_copy);

my $long='u' x 128;
my $model=Skein::Model->new({noise=>[{name=>$long,p=>'1/3'}],
    nodes=>[{name=>'g_0',expr=>var($long)}],queries=>[{name=>'q',event=>var('g_0')}]});
is(Skein::Engine->new($model)->solve('q')->{probability},'1/3','maximum source identifier accepted symbolically');
is(Skein::Eliminate->new($model)->solve('q')->{probability},'1/3','internal factor names do not exceed source identifier bounds');
my $collision=Skein::Model->from_text('noise g_0 ~ 1/3; noise u_0 ~ 1/4; node g_1 = g_0 ^ u_0; query q = P(g_1);');
is(Skein::Eliminate->new($collision)->solve('q')->{probability},'5/12','source names cannot collide with either internal gate namespace');
my $base=Skein::Model->from_file('examples/rack.sk');
for my $kind (qw(sensors intervals order title)) {
    my $raw=$base->raw;
    if ($kind eq 'sensors') { $raw->{sensors}[0]{cost}++ }
    elsif ($kind eq 'intervals') { $raw->{intervals}{power_noise}[0]='1/250' }
    elsif ($kind eq 'order') { $raw->{order}=[reverse @{$raw->{order}}] }
    else { $raw->{title}='Different title' }
    my $changed=Skein::Model->new($raw);
    my $diff=Skein::Compare->model_diff($base,$changed);
    is(scalar @{$diff->{changes}},1,"model comparison includes $kind changes");
}
my $bad=eval { Skein::Mission->new({horizon=>1,processes=>[{name=>$long,failure=>'1/2',repair=>'1/2'}]}); 1 };
ok(!$bad,'mission expansion bounds are checked at specification validation');
like($@,qr/expansion limit/,'mission expansion error is explicit');
my $mission=Skein::Mission->new({horizon=>1,processes=>[{name=>'a'x100,failure=>'1/3',repair=>'1/2'}]});
ok($mission->build->digest,'long permitted mission names compile');
done_testing;
