class CreateFederationReconciliationRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :federation_reconciliation_runs do |t|
      t.string :status, null: false, default: "completed" # completed, failed
      t.integer :critical_count, default: 0
      t.integer :warning_count, default: 0
      t.integer :total_findings, default: 0
      t.jsonb :issues, default: []
      t.string :error_message
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :federation_reconciliation_runs, :created_at
  end
end
