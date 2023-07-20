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

    #return if $action ne 'create';
    return if $biblio->items->count;

    if ($0 =~ m/addorder.pl/gi) {
        my $default_homebranch    = $self->retrieve_data('default_homebranch');
        my $default_holdingbranch = $self->retrieve_data('default_holdingbranch');
        my $default_itype         = $self->retrieve_data('default_itype');

        my $item = Koha::Item->new({
            homebranch    => $default_homebranch,
            holdingbranch => $default_holdingbranch,
            itype         => $default_itype,
            biblionumber  => $biblio->id,
        })->store;
    }
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
