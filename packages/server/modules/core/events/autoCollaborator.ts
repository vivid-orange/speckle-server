import type { EventBus, EventPayload } from '@/modules/shared/services/eventBus'
import { UserEvents } from '@/modules/core/domain/users/events'
import { ProjectEvents } from '@/modules/core/domain/projects/events'
import { StreamAcl, Streams, Users } from '@/modules/core/dbSchema'
import { Roles } from '@/modules/core/helpers/mainConstants'
import type { Logger } from '@/observability/logging'
import type { Knex } from 'knex'

/**
 * Inserts contributor ACL rows for a single user across all existing projects.
 * Uses INSERT ... SELECT so no rows are loaded into Node memory.
 */
export const grantContributorToAllProjectsFactory =
  ({ db }: { db: Knex }) =>
  async (userId: string): Promise<number> => {
    const result = await db.raw(
      `INSERT INTO ?? ("userId", "resourceId", "role")
       SELECT ?, ??, ?
       FROM ??
       ON CONFLICT ("userId", "resourceId") DO NOTHING`,
      [StreamAcl.name, userId, Streams.col.id, Roles.Stream.Contributor, Streams.name]
    )

    return result.rowCount ?? 0
  }

/**
 * Inserts contributor ACL rows for all existing users on a single project.
 * Excludes `excludeUserId` (typically the project owner who already has stream:owner).
 * Uses INSERT ... SELECT so no rows are loaded into Node memory.
 */
export const grantAllUsersContributorFactory =
  ({ db }: { db: Knex }) =>
  async (projectId: string, excludeUserId: string): Promise<number> => {
    const result = await db.raw(
      `INSERT INTO ?? ("userId", "resourceId", "role")
       SELECT ??, ?, ?
       FROM ??
       WHERE ?? != ?
       ON CONFLICT ("userId", "resourceId") DO NOTHING`,
      [
        StreamAcl.name,
        Users.col.id,
        projectId,
        Roles.Stream.Contributor,
        Users.name,
        Users.col.id,
        excludeUserId
      ]
    )

    return result.rowCount ?? 0
  }

type GrantContributorToAllProjects = ReturnType<typeof grantContributorToAllProjectsFactory>
type GrantAllUsersContributor = ReturnType<typeof grantAllUsersContributorFactory>

const onUserCreatedFactory =
  (deps: { grantContributorToAllProjects: GrantContributorToAllProjects; logger: Logger }) =>
  async ({ payload }: EventPayload<typeof UserEvents.Created>) => {
    const { user } = payload
    const logger = deps.logger.child({
      autoCollaborator: true,
      userId: user.id
    })

    try {
      logger.info('Auto-adding new user to all existing projects...')

      const insertedRows = await deps.grantContributorToAllProjects(user.id)

      logger.info(
        { insertedRows },
        'Finished auto-adding new user to existing projects'
      )
    } catch (err) {
      logger.error({ err }, 'Failed to auto-add new user to existing projects')
    }
  }

const onProjectCreatedFactory =
  (deps: { grantAllUsersContributor: GrantAllUsersContributor; logger: Logger }) =>
  async ({ payload }: EventPayload<typeof ProjectEvents.Created>) => {
    const { project, ownerId } = payload
    const logger = deps.logger.child({
      autoCollaborator: true,
      projectId: project.id
    })

    try {
      logger.info('Auto-adding all existing users to new project...')

      const insertedRows = await deps.grantAllUsersContributor(project.id, ownerId)

      logger.info(
        { insertedRows },
        'Finished auto-adding existing users to new project'
      )
    } catch (err) {
      logger.error({ err }, 'Failed to auto-add existing users to new project')
    }
  }

export const autoCollaboratorListenersFactory =
  (deps: {
    eventBus: EventBus
    grantContributorToAllProjects: GrantContributorToAllProjects
    grantAllUsersContributor: GrantAllUsersContributor
    logger: Logger
  }) =>
  () => {
    const onUserCreated = onUserCreatedFactory(deps)
    const onProjectCreated = onProjectCreatedFactory(deps)

    const cbs = [
      deps.eventBus.listen(UserEvents.Created, onUserCreated),
      deps.eventBus.listen(ProjectEvents.Created, onProjectCreated)
    ]

    return () => cbs.forEach((cb) => cb())
  }
