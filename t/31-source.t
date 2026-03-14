use strict;
use warnings;
use utf8;
use Test::More;
use Skein::Model;
use Skein::Source;
use Skein::Util qw(canonical_json);

for my $path (qw(rack confounding diagnosis voter)) {
    my $model = Skein::Model->from_file("examples/$path.sk");
    my $source = Skein::Source->emit($model);
    my $copy = Skein::Model->from_text($source);
    is($copy->digest, $model->digest, "$path retains every normalized declaration");
    is(Skein::Source->emit($copy), $source, "$path source is stable after reparse");
}
my $model = Skein::Model->from_text('model empty; title "雪\\nquoted \\"title\\""; query q = P(1) given(1) factual(1);');
my $copy = Skein::Model->from_text(Skein::Source->emit($model));
is(canonical_json($copy->raw), canonical_json($model->raw),'Unicode, escapes, constants and optional clauses round trip');
my $raw = $model->raw;
$raw->{title} = "line\rreturn\ttab";
$model = Skein::Model->new($raw);
is(Skein::Model->from_text(Skein::Source->emit($model))->title,$model->title,'all emitted control escapes can be read');
done_testing;
