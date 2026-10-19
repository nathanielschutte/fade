
# Plan

Central task tracking doc for napsack. Divides into categories ("Epics"), and a Tracker at the top which is a table with tasks from the below Epics that are actively being worked on.

## Tracker

> Insert table here


## Epics

### Features

- iOS app. This is the big one.

- Password reset flow - email?  Admin recovery key for support.

- Text chat pagination. We DO want texts to live forever. Make sure the clients use pagination for when chat history grows extensively.

- User profile page.  View your list of friends and some stats that belong to you. Friends can view each other's profiles.

- Profile pic. Nicknames settable by own user.

- Write text caption on a picture before you send it.

- Group chats (encryption design implication)


### Debug

- Log viewer (also for admins only). Central view of server logs with search features. Along with this, take a pass at the server code and improve logging. Debug logging can be verbose.

- Client side debug logs. Browser/iOS client debug logs should be viewable in the admin log viewer as well (see above)


### Experience/visual

- Remove the word 'snap', let's refer to pictures as something else


### Infrastructure

- Migrate compute to an EC2 ASG, set desired size to 1 for now
    - Eventually enable auto scaling rules, for now keep static
    - Will need to rethink deployment. Bake a new AMI and swap it out? Run deploy script across all ASG instances in parallel?
    - Filesystem/DB needs to move to EFS or similar instead of EBS.

- DB backup system (depends on above)
