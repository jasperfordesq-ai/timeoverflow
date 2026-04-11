class FederationCcNodeConfig < ActiveRecord::Base
  belongs_to :organization, optional: true

  validates :node_slug, presence: true, uniqueness: true,
            format: { with: /\A[0-9a-z-]{3,15}\z/, message: "must be 3-15 lowercase alphanumeric or hyphen characters" }
  validates :exchange_rate, numericality: { greater_than: 0 }
  validates :validated_window, numericality: { greater_than: 0 }

  def self.for(organization)
    org_id = organization.is_a?(Integer) ? organization : organization.id
    find_or_create_by!(organization_id: org_id) do |config|
      config.node_slug = "timeoverflow-#{org_id}"
      config.currency_format = "%s hours"
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(organization_id: org_id)
  end

  def root_node?
    parent_node_url.blank?
  end

  def build_about_response
    org = Organization.find_by(id: organization_id)
    {
      format: currency_format,
      rate: exchange_rate.to_f,
      absolute_path: [node_slug],
      validated_window: validated_window,
      trades: FederationTransaction.where(organization_id: organization_id).completed.count,
      traders: FederationTransaction.where(organization_id: organization_id).completed.select(:remote_user_identifier).distinct.count,
      volume: FederationTransaction.where(organization_id: organization_id).completed.sum(:amount),
      accounts: (org ? org.members.active.count : 0)
    }
  end
end
