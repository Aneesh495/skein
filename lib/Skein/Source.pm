package Skein::Source;
use 5.020;
use strict;
use warnings;
use Skein::Expr qw(render);
use Skein::Util qw(write_text);

# A deterministic source emitter makes every generated case inspectable.
# It preserves syntax-sensitive optional query clauses, including given(1).
sub _string {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    $value =~ s/\n/\\n/g;
    $value =~ s/\r/\\r/g;
    $value =~ s/\t/\\t/g;
    return '"' . $value . '"';
}

sub emit {
    my ($class, $model) = @_;
    die "source emitter requires a structural model\n"
        unless ref($model) && $model->isa('Skein::Model');
    my $raw = $model->raw;
    my @lines = ('model ' . $raw->{name} . ';');
    push @lines, 'title ' . _string($raw->{title}) . ';' if length $raw->{title};
    push @lines, '';
    for my $item (@{$raw->{noise}}) {
        push @lines, 'noise ' . $item->{name} . ' ~ ' . $item->{p} . ';';
    }
    push @lines, '';
    for my $name (@{$model->node_order}) {
        push @lines, 'node ' . $name . ' = ' . render($model->equation($name)) . ';';
    }
    push @lines, '';
    for my $item (@{$raw->{queries}}) {
        my $line = 'query ' . $item->{name} . ' = P(' . render($item->{event}) . ')';
        $line .= ' given(' . render($item->{evidence}) . ')' if exists $item->{evidence};
        $line .= ' factual(' . render($item->{factual}) . ')' if exists $item->{factual};
        if (keys %{$item->{interventions}}) {
            $line .= ' do(' . join(', ', map {
                $_ . '=' . $item->{interventions}{$_}
            } sort keys %{$item->{interventions}}) . ')';
        }
        push @lines, $line . ';';
    }
    push @lines, '';
    for my $item (@{$raw->{repairs}}) {
        push @lines, 'repair ' . $item->{name} . ' = ' . $item->{node}
            . '=' . $item->{value} . ' cost ' . $item->{cost} . ';';
    }
    for my $item (@{$raw->{sensors}}) {
        push @lines, 'sensor ' . $item->{name} . ' = ' . render($item->{expr})
            . ' cost ' . $item->{cost} . ';';
    }
    for my $name (sort keys %{$raw->{intervals}}) {
        push @lines, 'interval ' . $name . ' = ['
            . join(', ', @{$raw->{intervals}{$name}}) . '];';
    }
    push @lines, 'order ' . join(', ', @{$raw->{order}}) . ';' if @{$raw->{order}};
    return join("\n", @lines) . "\n";
}

sub save {
    my ($class, $model, $path) = @_;
    return write_text($path, $class->emit($model));
}

1;
