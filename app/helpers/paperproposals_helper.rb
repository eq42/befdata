module PaperproposalsHelper
  def paperproposal_state_to_i(paperproposal = @paperproposal)
    case paperproposal.board_state
      when 'prep', 're_prep' then 1
      when 'submit' then 2
      when 'data_rejected' then 3
      when 'accept' then 4
      when 'final' then 5
      else 0
    end
  end

  def compare_progress_class(elements_state_number, paperproposal = @paperproposal)
    case elements_state_number <=> paperproposal_state_to_i(paperproposal)
      when -1 then 'state-less'
      when 0 then 'state-equal'
      when 1 then 'state-greater'
    end
  end

  def proposal_is_accepted?
    return false unless @paperproposal
    @paperproposal.state == 'accepted'
  end

  def is_paperproposal_author?
    return false unless @paperproposal && current_user
    @paperproposal.author == current_user
  end

  def author_may_edit?
    is_paperproposal_author? && @paperproposal.lock == false
  end

  def author_may_edit_datasets?
    author_may_edit? && @paperproposal.board_state != 'final'
  end

  def may_administrate_paperproposals?
    return false unless current_user
    current_user.has_role?(:admin) || current_user.has_role?(:data_admin)
  end

  def limited_edit_of_final?
    @paperproposal.board_state == 'final' && !may_administrate_paperproposals? && is_paperproposal_author?
  end

  def votes_choices_for_select
    vote_choices = ['accept', 'reject']
    vote_choices << 'none' if current_user.has_role?(:admin)
    vote_choices
  end
end
