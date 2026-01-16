
use Modern::Perl;

use Koha::Biblios; 
use Koha::Plugins;
use Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator;

use Getopt::Long qw( GetOptions );

my $biblionumber;

GetOptions(
    'b|biblionumber:i' => \$biblionumber,
);

die "Must provide a biblionumber" unless $biblionumber;

my $biblio = Koha::Biblios->find({ biblionumber => $biblionumber });


die "Biblio not found" unless $biblio;

my $plugin = Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator->new();
$plugin->after_biblio_action({action=>"create", biblio=>$biblio});
