class ProjectsController < ApplicationController
  before_filter :load_project, :only => [:show, :edit, :update, :destroy]
  skip_before_filter :deny_access_to_all
  access_control do
    actions :index, :show do
      allow all
    end
    actions :new, :create, :edit, :update, :destroy do
      allow :admin
    end
  end

  def index
    @projects = Project.all( :order => "shortname")
  end

  def show
    @project_datasets = @project.datasets.order(:title).uniq
    @deletable = (@project_datasets.count + @project.users.count + @project.authored_paperproposals.count) == 0
  end

  def new
    @project = Project.new()
    # initialize two select boxes for pi and phd student
    @roles = [{name: :pi, id: []},{name: "phd student", id: []}]
  end

  def create
    @project = Project.new(params[:project])
    if @project.save
      unless params[:roles].blank?
        params[:roles].each do |role|
          @project.set_user_with_role(role[:type], User.find(role[:value] || []))
        end
      end
      redirect_to projects_path, notice: "Successfully Added project #{@project.shortname}"
    else
      render :new
    end
  end
  def edit
    @roles = @project.accepted_roles.collect{|r| {name: r.name, id: r.users.map(&:id)}}
  end
  def update
    if @project.update_attributes(params[:project])
      roles_config = params[:roles].blank? ? [] : params[:roles]
      to_be_delete = @project.accepted_roles.map(&:name) - roles_config.map{|r| r["type"]}
      to_be_delete.each do |role|
        @project.set_user_with_role(role, [])
      end
      roles_config.each do |role|
        @project.set_user_with_role(role[:type], User.find(role[:value] || []))
      end
      redirect_to project_path(@project), notice: "Successfully saved project #{@project.name}"
    else
      render :edit
    end
  end
  def destroy
    name = @project.name
    if @project.destroy
      redirect_to projects_path, :notice => "Successfully destroyed Prject: #{name}"
    else
      redirect_to projects_path, :error => @project.errors.full_messages.to_sentence
    end
  end
private
  def load_project
    @project = Project.find(params[:id])
  end
end
