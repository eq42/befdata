class Categoricvalue < ActiveRecord::Base

  has_many :sheetcells, :as => :value
  ## if there is any measurement linked to a category,
  ## it should not be destroyed; If there is a reason to change this
  ## category, it should only be changed
  ## before_destroy :no_measurement_linked?
  has_many :import_categoricvalues

  # tagging
  is_taggable :tags, :languages

  validates_presence_of :short, :long, :description
  ## does not work, no "column" "data_group"... p. 398 in the rails book has
  ## solution
  ## validates_uniqueness_of :short, :long, :description, :scope => :data_group
  ## within one method, categories should be unique
  ## categoricvalues are linked via measurements - submethods to methods

  before_destroy :check_for_measurements, :check_for_import_categories
  after_destroy :destroy_taggings

  ## !! before save we should check if all is given: short, long, description

  def verbose
    "#{short} -- #{long} -- #{description}"
  end

  def show_value
    "#{long} (#{short})"
  end
  
  def check_for_measurements
    cat = self.reload
    unless cat.sheetcells.length == 0
      errors.add_to_base "Cannot destroy categoric value with Data Cells associations"
      false
    end
  end

  def check_for_import_categories
    cat = self.reload
    unless cat.import_categoricvalues.length == 0
      errors.add_to_base "Cannot destroy categoric value with Import Categories associations"
      false
    end
  end

  def destroy_taggings
    logger.debug "in destroy taggings"
    cds = self.taggings.destroy_all
  end

  def to_label
    short
  end


end
