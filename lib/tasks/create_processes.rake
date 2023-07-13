# frozen_string_literal: true

require "decidim/faker/localized"
require "decidim/faker/internet"

namespace :decidim do
  desc "Create some more processes"
  task create_processes: :environment do
    organization = Decidim::Organization.first
    seeds_root = File.join(__dir__, "..", "..", "db", "seeds")

    create_processes(6, organization, seeds_root, promoted: true, start_date: Date.current, end_date: 2.months.from_now)
    create_processes(6, organization, seeds_root, promoted: false, start_date: Date.current, end_date: 2.months.from_now, participatory_process_group: nil)

    create_processes(6, organization, seeds_root, promoted: false, start_date: 4.months.ago, end_date: 2.months.ago)
    create_processes(6, organization, seeds_root, promoted: false, start_date: 4.months.ago, end_date: 2.months.ago, participatory_process_group: nil)

    create_processes(6, organization, seeds_root, promoted: false, start_date: 2.weeks.from_now, end_date: 2.months.from_now)
    create_processes(6, organization, seeds_root, promoted: false, start_date: 2.weeks.from_now, end_date: 2.months.from_now, participatory_process_group: nil)
  end
end

def add_proposals(participatory_space)
  admin_user = Decidim::User.find_by(
    organization: participatory_space.organization,
    email: "admin@example.org"
  )

  step_settings = if participatory_space.allows_steps?
                    { participatory_space.active_step.id => { votes_enabled: true, votes_blocked: false, creation_enabled: true } }
                  else
                    {}
                  end

  params = {
    name: Decidim::Components::Namer.new(participatory_space.organization.available_locales, :proposals).i18n_name,
    manifest_name: :proposals,
    published_at: Time.current,
    participatory_space: participatory_space,
    settings: {
      vote_limit: 0,
      collaborative_drafts_enabled: true
    },
    step_settings: step_settings
  }

  component = Decidim.traceability.perform_action!(
    "publish",
    Decidim::Component,
    admin_user,
    visibility: "all"
  ) do
    Decidim::Component.create!(params)
  end

  if participatory_space.scope
    scopes = participatory_space.scope.descendants
    global = participatory_space.scope
  else
    scopes = participatory_space.organization.scopes
    global = nil
  end

  5.times do |n|
    state, answer, state_published_at = if n > 3
                                          ["accepted", Decidim::Faker::Localized.sentence(word_count: 10), Time.current]
                                        elsif n > 2
                                          ["rejected", nil, Time.current]
                                        elsif n > 1
                                          ["evaluating", nil, Time.current]
                                        elsif n.positive?
                                          ["accepted", Decidim::Faker::Localized.sentence(word_count: 10), nil]
                                        else
                                          [nil, nil, nil]
                                        end

    params = {
      component: component,
      category: participatory_space.categories.sample,
      scope: Faker::Boolean.boolean(true_ratio: 0.5) ? global : scopes.sample,
      title: { en: Faker::Lorem.sentence(word_count: 2) },
      body: { en: Faker::Lorem.paragraphs(number: 2).join("\n") },
      state: state,
      answer: answer,
      answered_at: state.present? ? Time.current : nil,
      state_published_at: state_published_at,
      published_at: Time.current
    }

    proposal = Decidim.traceability.perform_action!(
      "publish",
      Decidim::Proposals::Proposal,
      admin_user,
      visibility: "all"
    ) do
      proposal = Decidim::Proposals::Proposal.new(params)
      meeting_component = participatory_space.components.find_by(manifest_name: "meetings")

      coauthor = case n
                 when 0
                   Decidim::User.where(decidim_organization_id: participatory_space.decidim_organization_id).order(Arel.sql("RANDOM()")).first
                 when 1
                   Decidim::UserGroup.where(decidim_organization_id: participatory_space.decidim_organization_id).order(Arel.sql("RANDOM()")).first
                 when 2
                   Decidim::Meetings::Meeting.where(component: meeting_component).order(Arel.sql("RANDOM()")).first

                 else
                   participatory_space.organization
                 end
      proposal.add_coauthor(coauthor)
      proposal.save!
      proposal
    end

    if proposal.state.nil?
      email = "amendment-author-#{participatory_space.underscored_name}-#{participatory_space.id}-#{n}-amend#{n}@example.org"
      name = "#{Faker::Name.name} #{participatory_space.id} #{n} amend#{n}"

      author = Decidim::User.find_or_initialize_by(email: email)
      author.update!(
        password: "password1234",
        password_confirmation: "password1234",
        name: name,
        nickname: "#{Faker::Twitter.unique.screen_name[0..14]}_#{n}_#{participatory_space.id}",
        organization: component.organization,
        tos_agreement: "1",
        confirmed_at: Time.current
      )

      group = Decidim::UserGroup.create!(
        name: Faker::Name.name,
        nickname: "#{Faker::Twitter.unique.screen_name[0..14]}_#{n}_#{participatory_space.id}",
        email: Faker::Internet.email,
        extended_data: {
          document_number: Faker::Code.isbn,
          phone: Faker::PhoneNumber.phone_number,
          verified_at: Time.current
        },
        decidim_organization_id: component.organization.id,
        confirmed_at: Time.current
      )

      Decidim::UserGroupMembership.create!(
        user: author,
        role: "creator",
        user_group: group
      )

      params = {
        component: component,
        category: participatory_space.categories.sample,
        scope: Faker::Boolean.boolean(true_ratio: 0.5) ? global : scopes.sample,
        title: { en: "#{proposal.title["en"]} #{Faker::Lorem.sentence(word_count: 1)}" },
        body: { en: "#{proposal.body["en"]} #{Faker::Lorem.sentence(word_count: 3)}" },
        state: "evaluating",
        answer: nil,
        answered_at: Time.current,
        published_at: Time.current
      }

      emendation = Decidim.traceability.perform_action!(
        "create",
        Decidim::Proposals::Proposal,
        author,
        visibility: "public-only"
      ) do
        emendation = Decidim::Proposals::Proposal.new(params)
        emendation.add_coauthor(author, user_group: author.user_groups.first)
        emendation.save!
        emendation
      end

      Decidim::Amendment.create!(
        amender: author,
        amendable: proposal,
        emendation: emendation,
        state: "evaluating"
      )
    end

    (n % 3).times do |m|
      email = "vote-author-#{participatory_space.underscored_name}-#{participatory_space.id}-#{n}-#{m}@example.org"
      name = "#{Faker::Name.name} #{participatory_space.id} #{n} #{m}"

      author = Decidim::User.find_or_initialize_by(email: email)
      author.update!(
        password: "password1234",
        password_confirmation: "password1234",
        name: name,
        nickname: "#{Faker::Twitter.unique.screen_name[0..14]}_#{n}_#{participatory_space.id}",
        organization: component.organization,
        tos_agreement: "1",
        confirmed_at: Time.current,
        personal_url: Faker::Internet.url,
        about: Faker::Lorem.paragraph(sentence_count: 2)
      )

      Decidim::Proposals::ProposalVote.create!(proposal: proposal, author: author) unless proposal.published_state? && proposal.rejected?
      Decidim::Proposals::ProposalVote.create!(proposal: emendation, author: author) if emendation
    end

    unless proposal.published_state? && proposal.rejected?
      (n * 2).times do |index|
        email = "endorsement-author-#{participatory_space.underscored_name}-#{participatory_space.id}-#{n}-endr#{index}@example.org"
        name = "#{Faker::Name.name} #{participatory_space.id} #{n} endr#{index}"

        author = Decidim::User.find_or_initialize_by(email: email)
        author.update!(
          password: "password1234",
          password_confirmation: "password1234",
          name: name,
          nickname: "#{Faker::Twitter.unique.screen_name[0..14]}_#{n}_#{participatory_space.id}",
          organization: component.organization,
          tos_agreement: "1",
          confirmed_at: Time.current
        )
        if index.even?
          group = Decidim::UserGroup.create!(
            name: Faker::Name.name,
            nickname: "#{Faker::Twitter.unique.screen_name[0..14]}_#{n}_#{participatory_space.id}",
            email: Faker::Internet.email,
            extended_data: {
              document_number: Faker::Code.isbn,
              phone: Faker::PhoneNumber.phone_number,
              verified_at: Time.current
            },
            decidim_organization_id: component.organization.id,
            confirmed_at: Time.current
          )

          Decidim::UserGroupMembership.create!(
            user: author,
            role: "creator",
            user_group: group
          )
        end
        Decidim::Endorsement.create!(resource: proposal, author: author, user_group: author.user_groups.first)
      end
    end

    (n % 3).times do
      author_admin = Decidim::User.where(organization: component.organization, admin: true).all.sample

      Decidim::Proposals::ProposalNote.create!(
        proposal: proposal,
        author: author_admin,
        body: Faker::Lorem.paragraphs(number: 2).join("\n")
      )
    end

    # byebug
    Decidim::Comments::Seed.comments_for(proposal)

    #
    # Collaborative drafts
    #
    state = if n > 3
              "published"
            elsif n > 2
              "withdrawn"
            else
              "open"
            end
    author = Decidim::User.where(organization: component.organization).all.sample

    draft = Decidim.traceability.perform_action!("create", Decidim::Proposals::CollaborativeDraft, author) do
      draft = Decidim::Proposals::CollaborativeDraft.new(
        component: component,
        category: participatory_space.categories.sample,
        scope: Faker::Boolean.boolean(true_ratio: 0.5) ? global : scopes.sample,
        title: Faker::Lorem.sentence(word_count: 2),
        body: Faker::Lorem.paragraphs(number: 2).join("\n"),
        state: state,
        published_at: Time.current
      )
      draft.coauthorships.build(author: participatory_space.organization)
      draft.save!
      draft
    end

    case n
    when 2
      author2 = Decidim::User.where(organization: component.organization).all.sample
      Decidim::Coauthorship.create(coauthorable: draft, author: author2)
      author3 = Decidim::User.where(organization: component.organization).all.sample
      Decidim::Coauthorship.create(coauthorable: draft, author: author3)
      author4 = Decidim::User.where(organization: component.organization).all.sample
      Decidim::Coauthorship.create(coauthorable: draft, author: author4)
      author5 = Decidim::User.where(organization: component.organization).all.sample
      Decidim::Coauthorship.create(coauthorable: draft, author: author5)
      author6 = Decidim::User.where(organization: component.organization).all.sample
      Decidim::Coauthorship.create(coauthorable: draft, author: author6)
    when 3
      author2 = Decidim::User.where(organization: component.organization).all.sample
      Decidim::Coauthorship.create(coauthorable: draft, author: author2)
    end

    Decidim::Comments::Seed.comments_for(draft)
  end

  Decidim.traceability.update!(
    Decidim::Proposals::CollaborativeDraft.all.sample,
    Decidim::User.where(organization: component.organization).all.sample,
    component: component,
    category: participatory_space.categories.sample,
    scope: Faker::Boolean.boolean(true_ratio: 0.5) ? global : scopes.sample,
    title: Faker::Lorem.sentence(word_count: 2),
    body: Faker::Lorem.paragraphs(number: 2).join("\n")
  )
end

def add_meetings(participatory_space, seeds_root)
  admin_user = Decidim::User.find_by(
    organization: participatory_space.organization,
    email: "admin@example.org"
  )

  params = {
    name: Decidim::Components::Namer.new(participatory_space.organization.available_locales, :meetings).i18n_name,
    published_at: Time.current,
    manifest_name: :meetings,
    participatory_space: participatory_space
  }

  component = Decidim.traceability.perform_action!(
    "publish",
    Decidim::Component,
    admin_user,
    visibility: "all"
  ) do
    Decidim::Component.create!(params)
  end

  if participatory_space.scope
    scopes = participatory_space.scope.descendants
    global = participatory_space.scope
  else
    scopes = participatory_space.organization.scopes
    global = nil
  end

  2.times do
    start_time = [rand(1..20).weeks.from_now, rand(1..20).weeks.ago].sample
    end_time = start_time + [rand(1..4).hours, rand(1..20).days].sample
    params = {
      component: component,
      scope: Faker::Boolean.boolean(true_ratio: 0.5) ? global : scopes.sample,
      category: participatory_space.categories.sample,
      title: Decidim::Faker::Localized.sentence(word_count: 2),
      description: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
        Decidim::Faker::Localized.paragraph(sentence_count: 3)
      end,
      location: Decidim::Faker::Localized.sentence,
      location_hints: Decidim::Faker::Localized.sentence,
      start_time: start_time,
      end_time: end_time,
      address: "#{Faker::Address.street_address} #{Faker::Address.zip} #{Faker::Address.city}",
      latitude: Faker::Address.latitude,
      longitude: Faker::Address.longitude,
      registrations_enabled: [true, false].sample,
      available_slots: (10..50).step(10).to_a.sample,
      author: participatory_space.organization,
      registration_terms: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
        Decidim::Faker::Localized.paragraph(sentence_count: 3)
      end,
      published_at: Faker::Boolean.boolean(true_ratio: 0.8) ? Time.current : nil
    }

    _hybrid_meeting = Decidim.traceability.create!(
      Decidim::Meetings::Meeting,
      admin_user,
      params.merge(
        title: Decidim::Faker::Localized.sentence(word_count: 2),
        type_of_meeting: :hybrid,
        online_meeting_url: "http://example.org"
      ),
      visibility: "all"
    )

    _online_meeting = Decidim.traceability.create!(
      Decidim::Meetings::Meeting,
      admin_user,
      params.merge(
        title: Decidim::Faker::Localized.sentence(word_count: 2),
        type_of_meeting: :online,
        online_meeting_url: "http://example.org"
      ),
      visibility: "all"
    )

    meeting = Decidim.traceability.create!(
      Decidim::Meetings::Meeting,
      admin_user,
      params,
      visibility: "all"
    )

    2.times do
      Decidim::Meetings::Service.create!(
        meeting: meeting,
        title: Decidim::Faker::Localized.sentence(word_count: 2),
        description: Decidim::Faker::Localized.sentence(word_count: 5)
      )
    end

    Decidim::Forms::Questionnaire.create!(
      title: Decidim::Faker::Localized.paragraph,
      description: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
        Decidim::Faker::Localized.paragraph(sentence_count: 3)
      end,
      tos: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
        Decidim::Faker::Localized.paragraph(sentence_count: 2)
      end,
      questionnaire_for: meeting
    )

    2.times do |n|
      email = "meeting-registered-user-#{meeting.id}-#{n}@example.org"
      name = "#{Faker::Name.name} #{meeting.id} #{n}"
      user = Decidim::User.find_or_initialize_by(email: email)

      user.update!(
        password: "password1234",
        password_confirmation: "password1234",
        name: name,
        nickname: "#{Faker::Twitter.unique.screen_name[0..14]}_#{n}_#{participatory_space.id}",
        organization: component.organization,
        tos_agreement: "1",
        confirmed_at: Time.current,
        personal_url: Faker::Internet.url,
        about: Faker::Lorem.paragraph(sentence_count: 2)
      )

      Decidim::Meetings::Registration.create!(
        meeting: meeting,
        user: user
      )
    end

    attachment_collection = Decidim::AttachmentCollection.create!(
      name: Decidim::Faker::Localized.word,
      description: Decidim::Faker::Localized.sentence(word_count: 5),
      collection_for: meeting
    )

    Decidim::Attachment.create!(
      title: Decidim::Faker::Localized.sentence(word_count: 2),
      description: Decidim::Faker::Localized.sentence(word_count: 5),
      attachment_collection: attachment_collection,
      attached_to: meeting,
      content_type: "application/pdf",
      file: ActiveStorage::Blob.create_and_upload!(
        io: File.open(File.join(seeds_root, "Exampledocument.pdf")),
        filename: "Exampledocument.pdf",
        content_type: "application/pdf",
        metadata: nil
      ) # Keep after attached_to
    )
    Decidim::Attachment.create!(
      title: Decidim::Faker::Localized.sentence(word_count: 2),
      description: Decidim::Faker::Localized.sentence(word_count: 5),
      attached_to: meeting,
      content_type: "image/jpeg",
      file: ActiveStorage::Blob.create_and_upload!(
        io: File.open(File.join(seeds_root, "city.jpeg")),
        filename: "city.jpeg",
        content_type: "image/jpeg",
        metadata: nil
      ) # Keep after attached_to
    )
    Decidim::Attachment.create!(
      title: Decidim::Faker::Localized.sentence(word_count: 2),
      description: Decidim::Faker::Localized.sentence(word_count: 5),
      attached_to: meeting,
      content_type: "application/pdf",
      file: ActiveStorage::Blob.create_and_upload!(
        io: File.open(File.join(seeds_root, "Exampledocument.pdf")),
        filename: "Exampledocument.pdf",
        content_type: "application/pdf",
        metadata: nil
      ) # Keep after attached_to
    )
  end

  authors = [
    Decidim::UserGroup.where(decidim_organization_id: participatory_space.decidim_organization_id).verified.sample,
    Decidim::User.where(decidim_organization_id: participatory_space.decidim_organization_id).all.sample
  ]

  authors.each do |author|
    user_group = nil

    if author.is_a?(Decidim::UserGroup)
      user_group = author
      author = user_group.users.sample
    end

    start_time = [rand(1..20).weeks.from_now, rand(1..20).weeks.ago].sample
    params = {
      component: component,
      scope: Faker::Boolean.boolean(true_ratio: 0.5) ? global : scopes.sample,
      category: participatory_space.categories.sample,
      title: Decidim::Faker::Localized.sentence(word_count: 2),
      description: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
        Decidim::Faker::Localized.paragraph(sentence_count: 3)
      end,
      location: Decidim::Faker::Localized.sentence,
      location_hints: Decidim::Faker::Localized.sentence,
      start_time: start_time,
      end_time: start_time + rand(1..4).hours,
      address: "#{Faker::Address.street_address} #{Faker::Address.zip} #{Faker::Address.city}",
      latitude: Faker::Address.latitude,
      longitude: Faker::Address.longitude,
      registrations_enabled: [true, false].sample,
      available_slots: (10..50).step(10).to_a.sample,
      author: author,
      user_group: user_group
    }

    Decidim.traceability.create!(
      Decidim::Meetings::Meeting,
      authors[0],
      params,
      visibility: "all"
    )
  end
end

def take_random(mdl, organization)
  mdl.where(organization: organization).order("RANDOM()").first
end

def create_processes(count, organization, seeds_root, options = {})
  count.times do |n|
    params = {
      title: Decidim::Faker::Localized.sentence(word_count: 5),
      slug: Decidim::Faker::Internet.unique.slug(words: nil, glue: "-"),
      subtitle: Decidim::Faker::Localized.sentence(word_count: 2),
      hashtag: "##{Faker::Lorem.word}",
      short_description: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
        Decidim::Faker::Localized.sentence(word_count: 3)
      end,
      description: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
        Decidim::Faker::Localized.paragraph(sentence_count: 3)
      end,
      organization: organization,
      hero_image: ActiveStorage::Blob.create_and_upload!(
        io: File.open(File.join(seeds_root, "city.jpeg")),
        filename: "hero_image.jpeg",
        content_type: "image/jpeg",
        metadata: nil
      ), # Keep after organization
      banner_image: ActiveStorage::Blob.create_and_upload!(
        io: File.open(File.join(seeds_root, "city2.jpeg")),
        filename: "banner_image.jpeg",
        content_type: "image/jpeg",
        metadata: nil
      ), # Keep after organization
      promoted: true,
      published_at: 2.weeks.ago,
      meta_scope: Decidim::Faker::Localized.word,
      developer_group: Decidim::Faker::Localized.sentence(word_count: 1),
      local_area: Decidim::Faker::Localized.sentence(word_count: 2),
      target: Decidim::Faker::Localized.sentence(word_count: 3),
      participatory_scope: Decidim::Faker::Localized.sentence(word_count: 1),
      participatory_structure: Decidim::Faker::Localized.sentence(word_count: 2),
      start_date: Date.current,
      end_date: 2.months.from_now,
      participatory_process_group: take_random(Decidim::ParticipatoryProcessGroup, organization),
      participatory_process_type: take_random(Decidim::ParticipatoryProcessType, organization),
      scope: n.positive? ? nil : Decidim::Scope.reorder(Arel.sql("RANDOM()")).first
    }.merge(options)

    process = Decidim.traceability.perform_action!(
      "publish",
      Decidim::ParticipatoryProcess,
      organization.users.first,
      visibility: "all"
    ) do
      Decidim::ParticipatoryProcess.create!(params)
    end
    process.add_to_index_as_search_resource

    Decidim::ParticipatoryProcessStep.find_or_initialize_by(
      participatory_process: process,
      active: true
    ).update!(
      title: Decidim::Faker::Localized.sentence(word_count: 1, supplemental: false, random_words_to_add: 2),
      description: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
        Decidim::Faker::Localized.paragraph(sentence_count: 3)
      end,
      start_date: 1.month.ago,
      end_date: 2.months.from_now
    )

    # Create users with specific roles
    Decidim::ParticipatoryProcessUserRole::ROLES.each do |role|
      email = "participatory_process_#{process.id}_#{role}@example.org"

      user = Decidim::User.find_or_initialize_by(email: email)
      user.update!(
        name: Faker::Name.name,
        nickname: "#{Faker::Twitter.unique.screen_name[0..14]}_#{process.id}",
        password: "decidim123456",
        password_confirmation: "decidim123456",
        organization: organization,
        confirmed_at: Time.current,
        locale: I18n.default_locale,
        tos_agreement: true
      )

      Decidim::ParticipatoryProcessUserRole.find_or_create_by!(
        user: user,
        participatory_process: process,
        role: role
      )
    end

    attachment_collection = Decidim::AttachmentCollection.create!(
      name: Decidim::Faker::Localized.word,
      description: Decidim::Faker::Localized.sentence(word_count: 5),
      collection_for: process
    )

    Decidim::Attachment.create!(
      title: Decidim::Faker::Localized.sentence(word_count: 2),
      description: Decidim::Faker::Localized.sentence(word_count: 5),
      attachment_collection: attachment_collection,
      content_type: "application/pdf",
      attached_to: process,
      file: ActiveStorage::Blob.create_and_upload!(
        io: File.open(File.join(seeds_root, "Exampledocument.pdf")),
        filename: "Exampledocument.pdf",
        content_type: "application/pdf",
        metadata: nil
      ) # Keep after attached_to
    )

    Decidim::Attachment.create!(
      title: Decidim::Faker::Localized.sentence(word_count: 2),
      description: Decidim::Faker::Localized.sentence(word_count: 5),
      attached_to: process,
      content_type: "image/jpeg",
      file: ActiveStorage::Blob.create_and_upload!(
        io: File.open(File.join(seeds_root, "city.jpeg")),
        filename: "city.jpeg",
        content_type: "image/jpeg",
        metadata: nil
      ) # Keep after attached_to
    )

    Decidim::Attachment.create!(
      title: Decidim::Faker::Localized.sentence(word_count: 2),
      description: Decidim::Faker::Localized.sentence(word_count: 5),
      attached_to: process,
      content_type: "application/pdf",
      file: ActiveStorage::Blob.create_and_upload!(
        io: File.open(File.join(seeds_root, "Exampledocument.pdf")),
        filename: "Exampledocument.pdf",
        content_type: "application/pdf",
        metadata: nil
      ) # Keep after attached_to
    )

    2.times do
      Decidim::Category.create!(
        name: Decidim::Faker::Localized.sentence(word_count: 5),
        description: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
          Decidim::Faker::Localized.paragraph(sentence_count: 3)
        end,
        participatory_space: process
      )
    end

    Faker::Twitter.unique.exclude :screen_name, [], Decidim::User.all.map(&:nickname)
    puts "Adding meetings..."
    add_meetings(process.reload, seeds_root)
    Decidim.component_manifests.each do |manifest|
      next if [:proposals, :meetings].include?(manifest.name)

      manifest.seed!(process.reload)
    end
    puts "Adding proposals..."
    add_proposals(process.reload)
  end
end
