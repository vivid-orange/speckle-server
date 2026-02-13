/* istanbul ignore file */
import crypto from 'crypto'
import sharp from 'sharp'
import passport from 'passport'
import type { IProfile, VerifyCallback } from 'passport-azure-ad'
import { OIDCStrategy } from 'passport-azure-ad'

import {
  UserInputError,
  UnverifiedEmailSSOLoginError
} from '@/modules/core/errors/userinput'

import { ServerInviteResourceType } from '@/modules/serverinvites/domain/constants'
import { getResourceTypeRole } from '@/modules/serverinvites/helpers/core'
import type { AuthStrategyBuilder } from '@/modules/auth/helpers/types'
import {
  getAzureAdClientId,
  getAzureAdClientSecret,
  getAzureAdIdentityMetadata,
  getAzureAdIssuer,
  getServerOrigin,
  getSessionSecret,
  isSSLServer
} from '@/modules/shared/helpers/envHelper'
import type { Request } from 'express'
import type { Optional } from '@speckle/shared'
import { ensureError } from '@speckle/shared'
import type { ServerInviteRecord } from '@/modules/serverinvites/domain/types'
import type {
  FinalizeInvitedServerRegistration,
  ResolveAuthRedirectPath,
  ValidateServerInvite
} from '@/modules/serverinvites/services/operations'
import type { PassportAuthenticateHandlerBuilder } from '@/modules/auth/domain/operations'
import type {
  FindOrCreateValidatedUser,
  LegacyGetUserByEmail,
  UpdateUser
} from '@/modules/core/domain/users/operations'
import type { GetServerInfo } from '@/modules/core/domain/server/operations'
import { EnvironmentResourceError } from '@/modules/shared/errors'
import { InviteNotFoundError } from '@/modules/serverinvites/errors'

/** Fields we read from the Entra ID token's _json claim (typed as `any` in @types/passport-azure-ad) */
interface EntraIdJsonClaims {
  email: string
  name?: string
}

interface AzureAdRequest extends Request {
  graphAccessToken?: string
}

/** Subset of the Microsoft Graph /me response we care about */
interface GraphMeResponse {
  companyName?: string | null
}

interface GraphProfileData {
  company?: string
  avatar?: string
}

const GRAPH_TIMEOUT_MS = 5000
/** Max base64 data-URL length that fits in the DB column (varchar 524 288). */
const MAX_AVATAR_BASE64_LENGTH = 524288

async function fetchGraphProfile(
  accessToken: string,
  logger: { warn: (obj: Record<string, unknown>, msg: string) => void }
): Promise<GraphProfileData> {
  const headers = { Authorization: `Bearer ${accessToken}` }
  const signal = AbortSignal.timeout(GRAPH_TIMEOUT_MS)
  const result: GraphProfileData = {}

  // Fetch company name and profile photo in parallel
  const [meRes, photoRes] = await Promise.allSettled([
    fetch('https://graph.microsoft.com/v1.0/me?$select=companyName', {
      headers,
      signal
    }),
    fetch('https://graph.microsoft.com/v1.0/me/photo/$value', { headers, signal })
  ])

  if (meRes.status === 'fulfilled' && meRes.value.ok) {
    const data = (await meRes.value.json()) as GraphMeResponse
    if (data.companyName) result.company = data.companyName
  } else if (meRes.status === 'rejected') {
    logger.warn({ err: meRes.reason }, 'Graph API /me request failed')
  } else if (meRes.status === 'fulfilled' && !meRes.value.ok) {
    logger.warn(
      { status: meRes.value.status },
      'Graph API /me returned non-OK status'
    )
  }

  if (photoRes.status === 'fulfilled' && photoRes.value.ok) {
    const originalBuffer = Buffer.from(await photoRes.value.arrayBuffer())
    let buffer: Buffer<ArrayBufferLike> = originalBuffer
    let contentType = photoRes.value.headers.get('content-type') || 'image/jpeg'

    // Resize if the base64 data-URL would exceed the DB column limit.
    // data:image/jpeg;base64, prefix is ~24 chars; base64 expands by ~4/3.
    const dataUrlOverhead = 30
    const maxBase64Bytes = MAX_AVATAR_BASE64_LENGTH - dataUrlOverhead
    const maxRawBytes = Math.floor((maxBase64Bytes * 3) / 4)

    if (originalBuffer.length > maxRawBytes) {
      try {
        buffer = await sharp(originalBuffer)
          .resize({ width: 256, height: 256, fit: 'cover' })
          .jpeg({ quality: 80 })
          .toBuffer()
        contentType = 'image/jpeg'
      } catch (err) {
        logger.warn({ err }, 'Failed to resize avatar, skipping')
        return result
      }
    }

    const avatar = `data:${contentType};base64,${buffer.toString('base64')}`
    if (avatar.length > MAX_AVATAR_BASE64_LENGTH) {
      logger.warn(
        { length: avatar.length },
        'Resized avatar still exceeds DB limit, skipping'
      )
    } else {
      result.avatar = avatar
    }
  } else if (photoRes.status === 'rejected') {
    logger.warn({ err: photoRes.reason }, 'Graph API photo request failed')
  } else if (photoRes.status === 'fulfilled' && !photoRes.value.ok) {
    logger.warn(
      { status: photoRes.value.status },
      'Graph API photo returned non-OK status'
    )
  }

  return result
}

/**
 * Fire-and-forget: fetches the user's profile from Microsoft Graph and
 * updates company/avatar in the DB if they differ from the current values.
 * Runs outside the auth request path so login is never delayed.
 */
function syncGraphProfileInBackground(params: {
  accessToken: string
  userId: string
  existingUser: { company?: string | null; avatar?: string | null } | null
  updateUser: UpdateUser
  logger: { warn: (obj: Record<string, unknown>, msg: string) => void }
}): void {
  const { accessToken, userId, existingUser, updateUser, logger } = params

  fetchGraphProfile(accessToken, logger)
    .then(async (graphProfile) => {
      const company = graphProfile.company || process.env.AZURE_AD_DEFAULT_COMPANY

      // Update company and avatar independently so a failure in one
      // (e.g. avatar too large) doesn't prevent the other from saving.
      if (company && (!existingUser || company !== existingUser.company)) {
        try {
          await updateUser(userId, { company })
        } catch (err) {
          logger.warn({ err }, 'Failed to sync company from Graph API')
        }
      }

      if (
        graphProfile.avatar &&
        (!existingUser || graphProfile.avatar !== existingUser.avatar)
      ) {
        try {
          await updateUser(userId, { avatar: graphProfile.avatar })
        } catch (err) {
          logger.warn({ err }, 'Failed to sync avatar from Graph API')
        }
      }
    })
    .catch((err) => {
      logger.warn({ err }, 'Background Graph profile sync failed')
    })
}

const azureAdStrategyBuilderFactory =
  (deps: {
    getServerInfo: GetServerInfo
    getUserByEmail: LegacyGetUserByEmail
    buildFindOrCreateUser: () => Promise<FindOrCreateValidatedUser>
    validateServerInvite: ValidateServerInvite
    finalizeInvitedServerRegistration: FinalizeInvitedServerRegistration
    resolveAuthRedirectPath: ResolveAuthRedirectPath
    passportAuthenticateHandlerBuilder: PassportAuthenticateHandlerBuilder
    updateUser: UpdateUser
  }): AuthStrategyBuilder =>
  async (
    app,
    sessionMiddleware,
    moveAuthParamsToSessionMiddleware,
    finalizeAuthMiddleware
  ) => {
    // Derive encryption key (32 chars) and IV (12 chars) for cookie-based OIDC state.
    // Uses HMAC with distinct labels so key and IV are cryptographically independent
    // and work regardless of session secret length.
    const sessionSecret = getSessionSecret()
    const encryptionKey = crypto
      .createHmac('sha256', sessionSecret)
      .update('azure-ad-cookie-key')
      .digest('hex')
      .substring(0, 32)
    const encryptionIv = crypto
      .createHmac('sha256', sessionSecret)
      .update('azure-ad-cookie-iv')
      .digest('hex')
      .substring(0, 12)

    const strategy = new OIDCStrategy(
      {
        identityMetadata: getAzureAdIdentityMetadata(),
        clientID: getAzureAdClientId(),
        responseType: 'code id_token',
        responseMode: 'form_post',
        issuer: getAzureAdIssuer(),
        redirectUrl: new URL('/auth/azure/callback', getServerOrigin()).toString(),
        allowHttpForRedirectUrl: !isSSLServer(),
        clientSecret: getAzureAdClientSecret(),
        scope: ['profile', 'email', 'openid', 'User.Read'],
        loggingLevel: process.env.NODE_ENV === 'development' ? 'info' : 'error',
        passReqToCallback: true,
        // Use cookies instead of session for OIDC state storage
        // This avoids session persistence issues with cross-site POST callbacks
        useCookieInsteadOfSession: true,
        cookieEncryptionKeys: [{ key: encryptionKey, iv: encryptionIv }],
        cookieSameSite: true // Sets SameSite=None; Secure (required for cross-site POST)
      },
      // Dunno why TS isn't picking up on the types automatically
      async (
        req: Request,
        _iss: string,
        _sub: string,
        profile: IProfile,
        accessToken: string,
        _refreshToken: string,
        done: VerifyCallback
      ) => {
        // Store the Graph API access token on the request for use in the callback
        const adReq = req as AzureAdRequest
        adReq.graphAccessToken = accessToken
        done(null, profile)
      }
    )

    passport.use(strategy)

    // 1. Auth init
    app.get(
      '/auth/azure',
      sessionMiddleware,
      moveAuthParamsToSessionMiddleware,
      deps.passportAuthenticateHandlerBuilder('azuread-openidconnect')
    )

    // 2. Auth finish callback
    app.post(
      '/auth/azure/callback',
      sessionMiddleware,
      deps.passportAuthenticateHandlerBuilder('azuread-openidconnect'),
      async (req, _res, next) => {
        const serverInfo = await deps.getServerInfo()
        let logger = req.log.child({
          authStrategy: 'entraId',
          serverVersion: serverInfo.version
        })

        const findOrCreateUser = await deps.buildFindOrCreateUser()

        try {
          // This is the only strategy that does its own type for req.user - easier to force type cast for now
          // than to refactor everything
          const profile = req.user as Optional<IProfile>
          if (!profile) {
            throw new EnvironmentResourceError('No profile provided by Entra ID')
          }

          logger = logger.child({ profileId: profile.oid })

          const json = profile._json as EntraIdJsonClaims
          const graphAccessToken = (req as AzureAdRequest).graphAccessToken

          const user = {
            email: json.email,
            name: json.name || profile.displayName || ''
          }

          const existingUser = await deps.getUserByEmail({ email: user.email })

          if (existingUser && !existingUser.verified) {
            throw new UnverifiedEmailSSOLoginError(undefined, {
              info: {
                email: user.email
              }
            })
          }

          // if there is an existing user, go ahead and log them in (regardless of
          // whether the server is invite only or not).
          if (existingUser) {
            const myUser = await findOrCreateUser({
              user
            })

            // Sync company and avatar from Graph API in the background (non-blocking)
            if (graphAccessToken) {
              syncGraphProfileInBackground({
                accessToken: graphAccessToken,
                userId: myUser.id,
                existingUser,
                updateUser: deps.updateUser,
                logger
              })
            }

            // ID is used later for verifying access token
            req.user = {
              ...profile,
              id: myUser.id,
              email: myUser.email
            }
            return next()
          }

          // if the server is invite only and we have no invite id, throw.
          if (serverInfo.inviteOnly && !req.session.token) {
            throw new UserInputError(
              'This server is invite only. Please authenticate yourself through a valid invite link.'
            )
          }

          // 2. if you have an invite it must be valid, both for invite only and public servers
          let invite: Optional<ServerInviteRecord> = undefined
          if (req.session.token) {
            invite = await deps.validateServerInvite(user.email, req.session.token)
          }

          // create the user
          const myUser = await findOrCreateUser({
            user: {
              ...user,
              role: invite
                ? getResourceTypeRole(invite.resource, ServerInviteResourceType)
                : undefined,
              verified: !!invite,
              signUpContext: {
                req,
                isInvite: !!invite,
                newsletterConsent: !!req.session.newsletterConsent
              }
            }
          })

          // Sync company and avatar from Graph API in the background (non-blocking)
          if (graphAccessToken) {
            syncGraphProfileInBackground({
              accessToken: graphAccessToken,
              userId: myUser.id,
              existingUser: null,
              updateUser: deps.updateUser,
              logger
            })
          }

          // ID is used later for verifying access token
          req.user = {
            ...profile,
            id: myUser.id,
            email: myUser.email,
            isNewUser: myUser.isNewUser,
            isInvite: !!invite
          }

          req.log = req.log.child({ userId: myUser.id })

          // use the invite
          await deps.finalizeInvitedServerRegistration(user.email, myUser.id)

          // Resolve redirect path
          req.authRedirectPath = deps.resolveAuthRedirectPath(invite)

          // return to the auth flow
          return next()
        } catch (err) {
          const e = ensureError(
            err,
            'Unexpected issue occured while authenticating with Entra ID'
          )

          switch (e.constructor) {
            case UserInputError:
            case UnverifiedEmailSSOLoginError:
            case InviteNotFoundError:
              logger.info(
                { err: e },
                'User input error during Entra ID authentication callback.'
              )
              break
            default:
              logger.error(e, 'Error during Entra ID authentication callback.')
          }
          //skip remaining route handlers and go to error handler
          return next(e)
        }
      },
      finalizeAuthMiddleware
    )

    return {
      id: 'azuread',
      name: process.env.AZURE_AD_ORG_NAME || 'Microsoft',
      icon: 'mdi-microsoft',
      color: 'blue darken-3',
      url: '/auth/azure',
      callbackUrl: new URL('/auth/azure/callback', getServerOrigin()).toString()
    }
  }

export default azureAdStrategyBuilderFactory
