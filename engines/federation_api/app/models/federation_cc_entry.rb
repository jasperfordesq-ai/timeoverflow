class FederationCcEntry < ActiveRecord::Base
  belongs_to :federation_transaction, optional: true

  STATES = %w[P V C E X].freeze

  validates :transaction_uuid, presence: true
  validates :payer, presence: true
  validates :payee, presence: true
  validates :quant, presence: true, numericality: { greater_than: 0 }
  validates :state, presence: true, inclusion: { in: STATES }

  scope :completed, -> { where(state: "C") }
  scope :pending, -> { where(state: "P") }
  scope :validated, -> { where(state: "V") }
  scope :for_organization, ->(org_id) { where(organization_id: org_id) }
  scope :involving, ->(account_path) { where("payer = ? OR payee = ?", account_path, account_path) }
end
