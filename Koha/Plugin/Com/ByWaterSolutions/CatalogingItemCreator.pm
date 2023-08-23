package Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;

use Koha::Account::Lines;
use Koha::Account;
use Koha::DateUtils;
use Koha::Libraries;
use Koha::Patron::Categories;
use Koha::Patron;
use Koha::Item;

use Cwd qw(abs_path);
use Data::Dumper;
use LWP::UserAgent;
use MARC::Record;
use Mojo::JSON qw(decode_json);
use URI::Escape qw(uri_unescape);

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

our $metadata = {
    name            => 'Auto-create Items on Record Creation',
    author          => 'Kyle M Hall',
    date_authored   => '2009-01-27',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Automatically create dummy items on new records to allow holds.'
};

sub new {
    my ($class, $args) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub after_biblio_action {
    my ($self, $params) = @_;

    my $action = $params->{action};
    my $biblio = $params->{biblio};

    return unless ($0 =~ m/marc_ordering_process.pl|addorder.pl|addorderiso2709.pl/gi);

    #return if $action ne 'create';
    return if $biblio->items->count;

    my $default_homebranch    = $self->retrieve_data('default_homebranch');
    my $default_holdingbranch = $self->retrieve_data('default_holdingbranch');
    my $default_itype         = $self->retrieve_data('default_itype');

    if ($default_itype =~ m/^\d\d\d\$\w$/) {
        my $record = $biblio->metadata->record;
        my ($field, $subfield) = split(/\$/, $default_itype);
        $default_itype = $record->subfield($field, $subfield);
    }

    my $item = Koha::Item->new({
        homebranch    => $default_homebranch,
        holdingbranch => $default_holdingbranch,
        itype         => $default_itype,
        biblionumber  => $biblio->id,
        notforloan    => "-1",
    })->store;

    # Assume we want the newest order related to this bib
    my $order = $biblio->active_orders->search({}, {order_by => {-desc => 'ordernumber'}})->single;
    return unless $order;

    my $record = $biblio->record;

    # Add the first 960$x to the orderline as the vendor note, they should all be the same
    my $new_order_vendornote = $record->subfield('960', 'x');
    my $old_order_vendornote = $order->order_vendornote || q{};
    $new_order_vendornote .= "\n" if ($new_order_vendornote || $old_order_vendornote);
    $order->order_vendornote($old_order_vendornote . $new_order_vendornote);

    # Build the tracking report fields into an internal note for the orderline
    my @f960s = $record->field('960');
    my @f961s = $record->field('961');

    my @order_internalnote;
    for (my $i = 0; $i < scalar @f960s; $i++) {
        my $branch     = $f961s[$i]->subfield('b');
        my $collection = $f960s[$i]->subfield('8');
        my $location   = $f960s[$i]->subfield('c');
        my $quantity   = $f960s[$i]->subfield('q');
        push(@order_internalnote, "$branch / $collection / $location / $quantity");
    }
    my $old_order_internalnote = $$order->order_internalnote || q{};
    unshift(@order_internalnote, $old_order_internalnote) if $old_order_internalnote;
    my $order_internalnote = join("\n", @order_internalnote);
    $order->order_vendornote($order_internalnote);

    $order->store();
}

sub configure {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    unless ($cgi->param('save')) {
        my $template = $self->get_template({file => 'configure.tt'});

        $template->param(
            default_homebranch    => $self->retrieve_data('default_homebranch'),
            default_holdingbranch => $self->retrieve_data('default_holdingbranch'),
            default_itype         => $self->retrieve_data('default_itype'),
        );

        $self->output_html($template->output());
    }
    else {
        $self->store_data({
            default_homebranch    => $cgi->param('default_homebranch'),
            default_holdingbranch => $cgi->param('default_holdingbranch'),
            default_itype         => $cgi->param('default_itype'),
        });
        $self->go_home();
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ($self, $args) = @_;

    return 1;
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ($self, $args) = @_;

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ($self, $args) = @_;

    return 1;
}

1;
