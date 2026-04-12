module FederationHub
  class PartnersController < BaseController
    def index
      @partners = FederationPartner.active.order(name: :asc)
    end

    def show
      @partner = FederationPartner.active.find(params[:id])
    end
  end
end
