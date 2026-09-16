import type { EventBus, EventPayload } from '@/modules/shared/services/eventBus'
import { UserEvents } from '@/modules/core/domain/users/events'
import { ProjectEvents } from '@/modules/core/domain/projects/events'
import { StreamAcl, Streams, Users } from '@/modules/core/dbSchema'
import { Roles } from '@/modules/core/helpers/mainConstants'
import type { Logger } from '@/observability/logging'
import type { Knex } from 'knex'

/** Shape of the pg driver result returned by the raw INSERTs below. */
type RawInsertResult = { rowCount?: number }

/**
 * Inserts contributor ACL rows for a single user across all existing projects.
 * Uses INSERT ... SELECT so no rows are loaded into Node memory.
 */
export const grantContributorToAllProjectsFactory =
  ({ db }: { db: Knex }) =>
  async (userId: string): Promise<number> => {
    const result = await db.raw<RawInsertResult>(
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
    const result = await db.raw<RawInsertResult>(
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

/**
 * Grants `stream:owner` to the configured auto-owner on a single project.
 * The account is resolved by email inside the statement, so a missing or renamed
 * account is a no-op rather than an error. Upserts, because the contributor sweep
 * will usually have already inserted a `stream:contributor` row for this user.
 */
export const grantAutoOwnerOnProjectFactory =
  ({ db }: { db: Knex }) =>
  async (projectId: string, ownerEmail: string): Promise<number> => {
    const result = await db.raw<RawInsertResult>(
      `INSERT INTO ?? ("userId", "resourceId", "role")
       SELECT ??, ?, ?
       FROM ??
       WHERE LOWER(??) = LOWER(?)
       ON CONFLICT ("userId", "resourceId") DO UPDATE SET "role" = EXCLUDED."role"`,
      [
        StreamAcl.name,
        Users.col.id,
        projectId,
        Roles.Stream.Owner,
        Users.name,
        Users.col.email,
        ownerEmail
      ]
    )

    return result.rowCount ?? 0
  }

/**
 * Grants `stream:owner` to a single user across all existing projects.
 * Used when the auto-owner's own account is (re-)created, so they are not left on
 * the `stream:contributor` rows the new-user sweep just inserted.
 */
export const grantOwnerOnAllProjectsFactory =
  ({ db }: { db: Knex }) =>
  async (userId: string): Promise<number> => {
    const result = await db.raw<RawInsertResult>(
      `INSERT INTO ?? ("userId", "resourceId", "role")
       SELECT ?, ??, ?
       FROM ??
       ON CONFLICT ("userId", "resourceId") DO UPDATE SET "role" = EXCLUDED."role"`,
      [StreamAcl.name, userId, Streams.col.id, Roles.Stream.Owner, Streams.name]
    )

    return result.rowCount ?? 0
  }

type GrantContributorToAllProjects = ReturnType<
  typeof grantContributorToAllProjectsFactory
>
type GrantAllUsersContributor = ReturnType<typeof grantAllUsersContributorFactory>
type GrantAutoOwnerOnProject = ReturnType<typeof grantAutoOwnerOnProjectFactory>
type GrantOwnerOnAllProjects = ReturnType<typeof grantOwnerOnAllProjectsFactory>

const onUserCreatedFactory =
  (deps: {
    grantContributorToAllProjects: GrantContributorToAllProjects
    grantOwnerOnAllProjects: GrantOwnerOnAllProjects
    autoOwnerEmail: string | null
    logger: Logger
  }) =>
  async ({ payload }: EventPayload<typeof UserEvents.Created>) => {
    const { user } = payload
    const logger = deps.logger.child({
      autoCollaborator: true,
      userId: user.id
    })

    const isAutoOwner =
      !!deps.autoOwnerEmail &&
      user.email?.toLowerCase() === deps.autoOwnerEmail.toLowerCase()

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

    if (!isAutoOwner) return

    // The sweep above just gave this account stream:contributor everywhere; the
    // configured auto-owner must outrank that on every project.
    try {
      logger.info('New user is the configured auto-owner, granting ownership...')

      const upgradedRows = await deps.grantOwnerOnAllProjects(user.id)

      logger.info(
        { upgradedRows },
        'Finished granting auto-owner ownership of all existing projects'
      )
    } catch (err) {
      logger.error(
        { err },
        'Failed to grant auto-owner ownership of all existing projects'
      )
    }
  }

const onProjectCreatedFactory =
  (deps: {
    grantAllUsersContributor: GrantAllUsersContributor
    grantAutoOwnerOnProject: GrantAutoOwnerOnProject
    autoOwnerEmail: string | null
    logger: Logger
  }) =>
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

    const { autoOwnerEmail } = deps
    if (!autoOwnerEmail) return

    // Must run after the contributor sweep, which will have inserted a
    // stream:contributor row for the auto-owner that this upsert overrides.
    try {
      logger.info('Granting configured auto-owner ownership of new project...')

      const grantedRows = await deps.grantAutoOwnerOnProject(project.id, autoOwnerEmail)

      if (!grantedRows) {
        logger.warn('Auto-owner email did not match any account, no ownership granted')
        return
      }

      logger.info(
        { grantedRows },
        'Finished granting auto-owner ownership of new project'
      )
    } catch (err) {
      logger.error({ err }, 'Failed to grant auto-owner ownership of new project')
    }
  }

export const autoCollaboratorListenersFactory =
  (deps: {
    eventBus: EventBus
    grantContributorToAllProjects: GrantContributorToAllProjects
    grantAllUsersContributor: GrantAllUsersContributor
    grantAutoOwnerOnProject: GrantAutoOwnerOnProject
    grantOwnerOnAllProjects: GrantOwnerOnAllProjects
    /**
     * Email of the account that should hold `stream:owner` on every project.
     * Null disables the auto-owner behaviour and leaves contributor grants alone.
     */
    autoOwnerEmail: string | null
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
