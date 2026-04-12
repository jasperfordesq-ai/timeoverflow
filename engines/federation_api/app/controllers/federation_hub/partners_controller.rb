module FederationHub
  class PartnersController < BaseController
    def index
      @external_partners = FederationPartner.active.order(name: :asc)
      @internal_orgs = Federation::InternalBrowser.browsable_organizations(current_organization)
    end

    def show
      @partner = FederationPartner.active.find(params[:id])
    end
  end
end
