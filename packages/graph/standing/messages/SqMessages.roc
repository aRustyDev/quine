module [
    SqCommand,
]

import ast.MvStandingQuery exposing [MvStandingQuery]
import state.SqPartState exposing [SqMsgSubscriber, SubscriptionResult]
import result.StandingQueryResult exposing [StandingQueryId, StandingQueryPartId]

## Commands delivered to a node for standing-query lifecycle management.
##
## CreateSqSubscription installs a new SQ subscription on this node.
## CancelSqSubscription tears down an existing subscription.
## NewSqResult delivers a subscription result from a child node.
## UpdateStandingQueries tells the node to re-evaluate all active SQs.
SqCommand : [
    CreateSqSubscription {
        subscriber : SqMsgSubscriber,
        query : MvStandingQuery,
        global_id : StandingQueryId,
    },
    CancelSqSubscription {
        subscriber : SqMsgSubscriber,
        query_part_id : StandingQueryPartId,
        global_id : StandingQueryId,
    },
    NewSqResult SubscriptionResult,
    UpdateStandingQueries,
]
